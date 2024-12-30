#include <sourcemod>

#define PLUGIN_NAME				"[L4D2] Remove Lobby Reservation"
#define PLUGIN_AUTHOR			"Downtown1, Anime4000, sorallll, lakwsh"
#define PLUGIN_DESCRIPTION		"Removes lobby reservation when server is full"
#define PLUGIN_VERSION			"3.1.0"
#define PLUGIN_URL				"http://forums.alliedmods.net/showthread.php?t=87759"

ConVar g_cvUnreserve, g_cvGameMode, g_cvLobbyOnly;
bool g_bUnreserve;

public Plugin myinfo = {
	name = PLUGIN_NAME,
	author = PLUGIN_AUTHOR,
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = PLUGIN_URL
};

public void OnPluginStart() {
	g_cvUnreserve = CreateConVar("l4d_unreserve_full", "1", "Automatically unreserve server after a full lobby joins", FCVAR_SPONLY|FCVAR_NOTIFY);
	g_cvUnreserve.AddChangeHook(CvarChanged_Unreserve);
	g_cvGameMode = FindConVar("mp_gamemode");
	g_cvLobbyOnly = FindConVar("sv_allow_lobby_connect_only");
	g_cvLobbyOnly.AddChangeHook(CvarChanged_LobbyOnly);

	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);

	RegAdminCmd("sm_unreserve", cmdUnreserve, ADMFLAG_KICK, "sm_unreserve - manually force removes the lobby reservation");
}

Action cmdUnreserve(int client, int args) {
	ServerCommand("sv_cookie 0");
	ReplyToCommand(client, "[UL] Lobby reservation has been removed.");
	return Plugin_Handled;
}

public void OnConfigsExecuted() {
	GetCvars();
}

void CvarChanged_Unreserve(ConVar convar, const char[] oldValue, const char[] newValue) {
	GetCvars();
}

void CvarChanged_LobbyOnly(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (!g_bUnreserve || convar.IntValue != 1)
		return;

	if (GetConnectedPlayer() >= GetMaxLobbySlots())
		convar.IntValue == 0;
}

void GetCvars() {
	g_bUnreserve = g_cvUnreserve.BoolValue;
}

public void OnClientConnected(int client) {
	if (!g_bUnreserve || (FindConVar("sv_maxplayers").IntValue == -1)) // plugin_unload
		return;

	if (IsFakeClient(client) || (GetConnectedPlayer() < GetMaxLobbySlots()))
		return;

	ServerCommand("sv_cookie 0");
}

// 不使用OnClientDisconnect防止换图过程误判 http://docs.sourcemod.net/api/index.php?fastload=show&id=390&
void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
	if (FindConVar("sv_maxplayers").IntValue == -1)
		return;

	char sCookie[20] = {0};
	FindConVar("sv_lobby_cookie").GetString(sCookie, sizeof(sCookie)); // plugin_unload
	if (StrEqual(sCookie, "0")) // 无大厅或者大厅未移除
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	int humans = GetConnectedPlayer();
	if (client && !IsFakeClient(client)) humans--;

	if (humans <= 0)
	{
		FindConVar("sv_lobby_cookie").SetString("0");
		g_cvLobbyOnly.IntValue = 1;
		return;
	}

	if (humans >= GetMaxLobbySlots())
		return;

	ServerCommand("sv_cookie %s", sCookie);
}

int GetMaxLobbySlots()
{
	char sGameMode[32] = {0};
	g_cvGameMode.GetString(sGameMode, sizeof(sGameMode));
	return (StrEqual(sGameMode, "versus") || StrEqual(sGameMode, "scavenge")) ? 8 : 4;
}

int GetConnectedPlayer() {
	int count = 0;
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientConnected(i) && !IsFakeClient(i))
			count++;
	}
	return count;
}