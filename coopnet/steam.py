"""Steam transport for coopnet: SteamNetworkingMessages through Valve's relay
network (no port forwarding), friend list and game invites. Uses the game's
own steam_api64.dll through the flat API with manual callback dispatch."""
import base64
import ctypes
import os
import time
from ctypes import c_bool, c_char_p, c_int, c_uint32, c_uint64, c_void_p

APP_ID = "1783560"
CODE_PREFIX = "TLC-"

CB_SESSION_REQUEST = 1251
CB_PERSONA_CHANGE = 304
CB_JOIN_REQUESTED = 337
FRIEND_CHANNEL = 1
PEER_QUIET = 10.0
SEND_UNRELIABLE = 0
SEND_NO_NAGLE = 1
SEND_RELIABLE = 8
SEND_AUTO_RESTART = 32
IDENTITY_STEAMID = 16
PERSONA_OFFLINE = 0
FRIEND_FLAG_IMMEDIATE = 4


class SteamUnavailable(Exception):
    pass


def encode_code(steam_id):
    raw = int(steam_id).to_bytes(8, "big")
    return CODE_PREFIX + base64.b32encode(raw).decode().rstrip("=").lower()


def decode_code(text):
    text = (text or "").strip().upper()
    if not text.startswith(CODE_PREFIX):
        return None
    body = text[len(CODE_PREFIX):]
    try:
        raw = base64.b32decode(body + "=" * (-len(body) % 8))
    except (ValueError, base64.binascii.Error):
        return None
    if len(raw) != 8:
        return None
    return int.from_bytes(raw, "big")


class Identity(ctypes.Structure):
    _fields_ = [("type", c_int), ("size", c_int), ("steam_id", c_uint64), ("_rest", ctypes.c_byte * 120)]

    @classmethod
    def of(cls, steam_id):
        return cls(IDENTITY_STEAMID, 8, steam_id)


class CallbackMsg(ctypes.Structure):
    _fields_ = [("user", c_int), ("callback", c_int), ("param", c_void_p), ("size", c_int)]


# Only the fields we read; the struct is released by the API.
class NetMessage(ctypes.Structure):
    _fields_ = [("data", c_void_p), ("size", c_int), ("conn", c_uint32), ("peer", Identity)]


class PersonaChange(ctypes.Structure):
    _fields_ = [("steam_id", c_uint64), ("flags", c_int)]


class JoinRequested(ctypes.Structure):
    _fields_ = [("friend", c_uint64), ("connect", ctypes.c_char * 256)]


class SteamLink:
    def __init__(self, dll_path, work_dir):
        if not dll_path or not os.path.isfile(dll_path):
            raise SteamUnavailable(f"hittar inte {dll_path}")
        # SteamAPI_Init reads the app id from steam_appid.txt in the working directory.
        os.makedirs(work_dir, exist_ok=True)
        with open(os.path.join(work_dir, "steam_appid.txt"), "w") as f:
            f.write(APP_ID)
        os.chdir(work_dir)
        try:
            dll = ctypes.CDLL(dll_path)
        except OSError as e:
            raise SteamUnavailable(str(e))
        self.dll = dll
        self._prototypes()
        err = ctypes.create_string_buffer(1024)
        if dll.SteamAPI_InitFlat(err) != 0:
            raise SteamUnavailable(err.value.decode(errors="replace") or "SteamAPI_InitFlat misslyckades")
        dll.SteamAPI_ManualDispatch_Init()
        self.pipe = dll.SteamAPI_GetHSteamPipe()
        self.user = c_void_p(dll.SteamAPI_SteamUser_v023())
        self.friends_if = c_void_p(dll.SteamAPI_SteamFriends_v018())
        self.msgs = c_void_p(dll.SteamAPI_SteamNetworkingMessages_SteamAPI_v002())
        dll.SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(c_void_p(dll.SteamAPI_SteamNetworkingUtils_SteamAPI_v004()))
        self.me = dll.SteamAPI_ISteamUser_GetSteamID(self.user)
        self.my_id = str(self.me)
        self.peer = None
        self.peer_heard = 0.0
        self.events = []
        self.q = []
        self.names_wanted = set()

    def _prototypes(self):
        d = self.dll
        d.SteamAPI_InitFlat.restype = c_int
        d.SteamAPI_GetHSteamPipe.restype = c_int
        d.SteamAPI_ManualDispatch_RunFrame.argtypes = [c_int]
        d.SteamAPI_ManualDispatch_GetNextCallback.argtypes = [c_int, ctypes.POINTER(CallbackMsg)]
        d.SteamAPI_ManualDispatch_GetNextCallback.restype = c_bool
        d.SteamAPI_ManualDispatch_FreeLastCallback.argtypes = [c_int]
        for name in ("SteamAPI_SteamUser_v023", "SteamAPI_SteamFriends_v018",
                     "SteamAPI_SteamNetworkingMessages_SteamAPI_v002", "SteamAPI_SteamNetworkingUtils_SteamAPI_v004"):
            getattr(d, name).restype = c_void_p
        d.SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess.argtypes = [c_void_p]
        d.SteamAPI_ISteamUser_GetSteamID.argtypes = [c_void_p]
        d.SteamAPI_ISteamUser_GetSteamID.restype = c_uint64
        d.SteamAPI_ISteamFriends_GetFriendCount.argtypes = [c_void_p, c_int]
        d.SteamAPI_ISteamFriends_GetFriendByIndex.argtypes = [c_void_p, c_int, c_int]
        d.SteamAPI_ISteamFriends_GetFriendByIndex.restype = c_uint64
        d.SteamAPI_ISteamFriends_GetFriendPersonaName.argtypes = [c_void_p, c_uint64]
        d.SteamAPI_ISteamFriends_GetFriendPersonaName.restype = c_char_p
        d.SteamAPI_ISteamFriends_GetFriendPersonaState.argtypes = [c_void_p, c_uint64]
        d.SteamAPI_ISteamFriends_InviteUserToGame.argtypes = [c_void_p, c_uint64, c_char_p]
        d.SteamAPI_ISteamFriends_InviteUserToGame.restype = c_bool
        d.SteamAPI_ISteamNetworkingMessages_SendMessageToUser.argtypes = [c_void_p, ctypes.POINTER(Identity), c_void_p, c_uint32, c_int, c_int]
        d.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel.argtypes = [c_void_p, c_int, ctypes.POINTER(ctypes.POINTER(NetMessage)), c_int]
        d.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser.argtypes = [c_void_p, c_void_p]
        d.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser.restype = c_bool
        d.SteamAPI_SteamNetworkingMessage_t_Release.argtypes = [ctypes.POINTER(NetMessage)]
        d.SteamAPI_ISteamFriends_RequestUserInformation.argtypes = [c_void_p, c_uint64, c_bool]
        d.SteamAPI_ISteamFriends_RequestUserInformation.restype = c_bool
        d.SteamAPI_ISteamFriends_SetRichPresence.argtypes = [c_void_p, c_char_p, c_char_p]
        d.SteamAPI_ISteamFriends_SetRichPresence.restype = c_bool
        d.SteamAPI_ISteamFriends_ClearRichPresence.argtypes = [c_void_p]

    def hello_lines(self):
        return [f"steam|0|me|{self.me}|{encode_code(self.me)}".encode()]

    def friends(self):
        d, out = self.dll, []
        for i in range(d.SteamAPI_ISteamFriends_GetFriendCount(self.friends_if, FRIEND_FLAG_IMMEDIATE)):
            fid = d.SteamAPI_ISteamFriends_GetFriendByIndex(self.friends_if, i, FRIEND_FLAG_IMMEDIATE)
            if d.SteamAPI_ISteamFriends_GetFriendPersonaState(self.friends_if, fid) == PERSONA_OFFLINE:
                continue
            name = (d.SteamAPI_ISteamFriends_GetFriendPersonaName(self.friends_if, fid) or b"?").decode("utf-8", "replace")
            out.append((fid, name))
        return out

    def status(self, sid):
        """Name and whether a (friend) Steam user is online right now."""
        d = self.dll
        name = (d.SteamAPI_ISteamFriends_GetFriendPersonaName(self.friends_if, sid) or b"?").decode("utf-8", "replace")
        return name, d.SteamAPI_ISteamFriends_GetFriendPersonaState(self.friends_if, sid) != PERSONA_OFFLINE

    def peer_id(self):
        return None if self.peer is None else str(self.peer)

    def name(self, sid):
        """Steam's name for an id now; for a stranger Steam is asked and the
        name comes later as an event."""
        d, sid = self.dll, int(sid)
        if d.SteamAPI_ISteamFriends_RequestUserInformation(self.friends_if, sid, True):
            self.names_wanted.add(sid)
            return ""
        name = (d.SteamAPI_ISteamFriends_GetFriendPersonaName(self.friends_if, sid) or b"").decode("utf-8", "replace")
        return "" if name in ("", "[unknown]") else name

    def presence(self, mode, world):
        d = self.dll
        if mode in ("", "menu"):
            d.SteamAPI_ISteamFriends_ClearRichPresence(self.friends_if)
            return
        status = f"Co-op: {mode} {world}".strip()
        d.SteamAPI_ISteamFriends_SetRichPresence(self.friends_if, b"status", status.encode("utf-8")[:255])
        if mode == "host":
            d.SteamAPI_ISteamFriends_SetRichPresence(self.friends_if, b"connect", f"-coopJoin={self.me}".encode())
        else:
            d.SteamAPI_ISteamFriends_SetRichPresence(self.friends_if, b"connect", b"")

    def send_q(self, to_id, data):
        try:
            ident = Identity.of(int(to_id))
        except ValueError:
            return
        self.dll.SteamAPI_ISteamNetworkingMessages_SendMessageToUser(
            self.msgs, ctypes.byref(ident), data, len(data), SEND_RELIABLE | SEND_AUTO_RESTART, FRIEND_CHANNEL)

    def receive_q(self):
        buf = (ctypes.POINTER(NetMessage) * 64)()
        while True:
            n = self.dll.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(self.msgs, FRIEND_CHANNEL, buf, 64)
            for i in range(n):
                m = buf[i].contents
                self.q.append((str(m.peer.steam_id), ctypes.string_at(m.data, m.size)))
                self.dll.SteamAPI_SteamNetworkingMessage_t_Release(buf[i])
            if n < 64:
                break
        q, self.q = self.q, []
        return q

    def invite(self, friend_id, connect):
        return self.dll.SteamAPI_ISteamFriends_InviteUserToGame(self.friends_if, int(friend_id), connect.encode())

    def send(self, data, reliable=True):
        if not self.peer:
            return
        flags = (SEND_RELIABLE if reliable else SEND_UNRELIABLE | SEND_NO_NAGLE) | SEND_AUTO_RESTART
        ident = Identity.of(self.peer)
        self.dll.SteamAPI_ISteamNetworkingMessages_SendMessageToUser(self.msgs, ctypes.byref(ident), data, len(data), flags, 0)

    def receive(self):
        out = []
        buf = (ctypes.POINTER(NetMessage) * 64)()
        while True:
            n = self.dll.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(self.msgs, 0, buf, 64)
            for i in range(n):
                m = buf[i].contents
                data = ctypes.string_at(m.data, m.size)
                sender, now = m.peer.steam_id, time.monotonic()
                # The first guest becomes the peer; a new one saying hello
                # replaces a guest that has gone quiet (it restarted its game).
                if self.peer is None or (sender != self.peer and data.startswith(b"hello|")
                                         and now - self.peer_heard > PEER_QUIET):
                    self.peer = sender
                    self.events.append(f"steam|0|peer|{self.peer}".encode())
                if sender == self.peer:
                    self.peer_heard = now
                    out.append(data)
                self.dll.SteamAPI_SteamNetworkingMessage_t_Release(buf[i])
            if n < 64:
                return out

    def tick(self):
        d = self.dll
        d.SteamAPI_ManualDispatch_RunFrame(self.pipe)
        msg = CallbackMsg()
        while d.SteamAPI_ManualDispatch_GetNextCallback(self.pipe, ctypes.byref(msg)):
            try:
                if msg.callback == CB_SESSION_REQUEST:
                    # Accepted from anyone: friend-list traffic (channel 1)
                    # comes from many. Only game traffic (channel 0, see
                    # receive) picks the peer, one guest at a time.
                    d.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(self.msgs, msg.param)
                elif msg.callback == CB_PERSONA_CHANGE:
                    sid = PersonaChange.from_address(msg.param).steam_id
                    if sid in self.names_wanted:
                        self.names_wanted.discard(sid)
                        name = (d.SteamAPI_ISteamFriends_GetFriendPersonaName(self.friends_if, sid) or b"").decode("utf-8", "replace")
                        if name not in ("", "[unknown]"):
                            self.events.append(f"steam|0|name|{sid}|{name.replace('|', '/')}".encode("utf-8"))
                elif msg.callback == CB_JOIN_REQUESTED:
                    connect = JoinRequested.from_address(msg.param).connect.decode("utf-8", "replace")
                    if connect.startswith("-coopJoin="):
                        self.events.append(f"steam|0|joinrequest|{connect.split('=', 1)[1].strip()}".encode())
            finally:
                d.SteamAPI_ManualDispatch_FreeLastCallback(self.pipe)

    def join(self, steam_id):
        self.peer = int(steam_id)

    def take_events(self):
        ev, self.events = self.events, []
        return ev
