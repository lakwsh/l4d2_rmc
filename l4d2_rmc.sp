#include <sourcemod>
#include <sdktools>

#define TEAM_SPECTATOR	1
#define TEAM_SURVIVOR	2
#define TEAM_INFECTED	3

#define isVaild(%1)			(%1>0 && %1<=MaxClients)
#define isBot(%1)			(IsClientInGame(%1) && IsFakeClient(%1))
#define isPlayer(%1)		(IsClientInGame(%1) && !IsFakeClient(%1))
#define isVaildPlayer(%1)	(isVaild(%1) && isPlayer(%1))
#define isSpectator(%1)		GetClientTeam(%1)==TEAM_SPECTATOR
#define isSurvivor(%1)		GetClientTeam(%1)==TEAM_SURVIVOR

Handle hSpec = INVALID_HANDLE, hSwitch = INVALID_HANDLE, hRespawn = INVALID_HANDLE, hGoAway = INVALID_HANDLE;
ConVar cMax, cCanAway, cAwayMode;
bool Enable, CanAway, RoundEnd;

enum Type{
	Bot,
	Survivor,
	Spectator,
	Player
};

public Plugin myinfo = {
	name = "[L4D2] Multiplayer",
	description = "L4D2 Multiplayer Plugin",
	author = "lakwsh",
	version = "1.6.0",
	url = "https://github.com/lakwsh/l4d2_rmc"
};

public void OnPluginStart(){
	cMax = FindConVar("sv_maxplayers");
	if(cMax==INVALID_HANDLE) SetFailState("L4DToolZ not found!");
	cMax.AddChangeHook(OnEnableChanged);
	Enable = GetConVarInt(cMax)!=-1;

	GameData hGameData = new GameData("l4d2_rmc");
	if(!hGameData){
		CloseHandle(hGameData);
		SetFailState("Failed to load 'l4d2_rmc.txt' gamedata.");
	}

	StartPrepSDKCall(SDKCall_Player);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SetHumanSpec")) SetFailState("Failed to find signature: SetHumanSpec");
	PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	hSpec = EndPrepSDKCall();
	if(hSpec==INVALID_HANDLE) SetFailState("Spectator Signature broken.");

	StartPrepSDKCall(SDKCall_Player);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "TakeOverBot")) SetFailState("Failed to find signature: TakeOverBot");
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	hSwitch = EndPrepSDKCall();
	if(hSwitch==INVALID_HANDLE) SetFailState("TakeOver Signature broken.");

	StartPrepSDKCall(SDKCall_Player);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "RoundRespawn")) SetFailState("Failed to find signature: Respawn");
	hRespawn = EndPrepSDKCall();
	if(hRespawn==INVALID_HANDLE) SetFailState("Respawn Signature broken.");

	StartPrepSDKCall(SDKCall_Player);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "GoAwayFromKeyboard")) SetFailState("Failed to find signature: GoAwayFromKeyboard");
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	hGoAway = EndPrepSDKCall();
	if(hGoAway==INVALID_HANDLE) SetFailState("GoAwayFromKeyboard Signature broken.");

	CloseHandle(hGameData);

	HookEvent("round_end", OnRoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_activate", OnActivate, EventHookMode_PostNoCopy);

	RegConsoleCmd("sm_jg", Cmd_Join);
	RegConsoleCmd("sm_away", Cmd_Away);
	RegConsoleCmd("sm_zs", Cmd_Kill);
	RegConsoleCmd("sm_info", Cmd_ShowInfo);
	RegAdminCmd("sm_fh", Cmd_Spawn, ADMFLAG_CHEATS, "复活");
	RegAdminCmd("sm_kb", Cmd_KickBot, ADMFLAG_KICK, "强制踢出机器人");
	RegAdminCmd("sm_setmax", Cmd_SetMax, ADMFLAG_KICK, "修改最大玩家数");

	cCanAway = CreateConVar("rmc_away", "1", "允许非管理员使用!away加入观察者", 0, true, 0.0, true, 1.0);
	cAwayMode = CreateConVar("rmc_awaymode", "0", "加入观察者类型 0=切换阵营模式 1=普通模式", 0, true, 0.0, true, 1.0);
	AutoExecConfig(true, "l4d2_rmc");

	SetConVarBounds(FindConVar("survivor_limit"), ConVarBound_Upper, true, 16.0);
	SetConVarBounds(FindConVar("z_max_player_zombies"), ConVarBound_Upper, true, 16.0);
}

public void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue){
	int val = StringToInt(newValue);
	Enable = val!=4 && val!=-1;
}

public void OnActivate(Event event, const char[] name, bool dontBroadcast){
	int uid = GetEventInt(event, "userid", 0);
	int client = GetClientOfUserId(uid);
	if(isVaildPlayer(client)){
		CheckSlots();
		CreateTimer(2.5, JointhemageR, uid);
	}
}

public Action JointhemageR(Handle timer, any uid){
	int client = GetClientOfUserId(uid);
	if(isVaildPlayer(client)){
		PrintToChat(client, "\x04[提示] \x01多人插件:\x05 %s", Enable?"开启":"关闭");
		PrintToChat(client, "\x05[说明] \x03!setmax \x04修改人数上限, \x03!info \x04显示人数信息");
		PrintToChat(client, "\x05[说明] \x03!jg \x04加入生还者, \x03!away \x04加入观察者, \x03!kb \x04踢出机器人");
		if(Enable){
			Cmd_ShowInfo(client, 0);
			Cmd_Join(client, 0);
		}
	}
	return Plugin_Stop;
}

public Action Cmd_SetMax(int client, int args){
	if(args==1){
		char tmp[3];
		GetCmdArg(1, tmp, sizeof(tmp));
		int max = StringToInt(tmp);
		if(max<1 || max>16) max = 4;
		SetConVarInt(cMax, max);
		CheckSlots();	// unreserved
		PrintToChatAll("\x05[提示]\x01 已修改人数上限为%d人", max);
	}
	return Plugin_Handled;
}

public void OnMapStart(){
	RoundEnd = false;
	CanAway = GetConVarBool(cCanAway);
}

public void OnRoundEnd(Event event, const char[] name, bool dontBroadcast){
	RoundEnd = true;
}

public void OnClientDisconnected(client){
	if(!RoundEnd && !IsFakeClient(client)) CheckSlots();
}

void CheckSlots(){
	if(!Enable) return;
	int max = GetConVarInt(cMax), total = Count(Survivor), need = Count(Player);
	if(total>max) BotControl(max);
	if(need>max || need-total<=0) return;

	if(max>4) ServerCommand("sv_unreserved");
	else ServerCommand("sv_allow_lobby_connect_only 1");
	SetConVarInt(FindConVar("survivor_limit"), need);
	SetConVarInt(FindConVar("z_max_player_zombies"), need);
	ServerCommand("sv_setmax %d", need>8?31:18);
	BotControl(need);
}

public Action Cmd_KickBot(int client, int args){
	BotControl(0);
	PrintToChatAll("\x05[提示]\x01 已踢出所有机器人");
	return Plugin_Handled;
}

public Action Cmd_Join(int client, int args){
	if(isVaildPlayer(client)){
		if(isSpectator(client)) Join(client);
		else PrintToChat(client, "\x05[加入失败] \x04请先加入观察者阵营");
	}
	return Plugin_Handled;
}

public Action Cmd_Kill(int client, int args){
	if(isVaildPlayer(client)){
		if(IsPlayerAlive(client)){
			ForcePlayerSuicide(client);
			char name[32];
			GetClientName(client, name, 32);
			PrintToChatAll("\x05[提示] \x04%s \x05升天了...", name);
		}
		else PrintToChat(client, "\x05[迷惑] \x04自杀? 你也配?");
	}
	return Plugin_Handled;
}

public Action Cmd_Away(int client, int args){
	if(!CanAway && !GetUserFlagBits(client)){
		PrintToChat(client, "\x05[失败] \x04非管理员不允许使用!away指令");
		return Plugin_Handled;
	}
	if(GetConVarBool(cAwayMode)) SDKCall(hGoAway, client);
	else ChangeClientTeam(client, TEAM_SPECTATOR);
	return Plugin_Handled;
}

public Action Cmd_ShowInfo(int client, int args){
	PrintToChat(client, "\x05[提示] \x03幸存者\x04[%i] \x03观察者\x04[%i] \x03Bot\x04[%i] \x03玩家\x04[%i] ", Count(Survivor), Count(Spectator), Count(Bot), Count(Player));
	return Plugin_Handled;
}

void BotControl(int need){
	int total = Count(Survivor);
	bool kick = total>need;
	int num = kick?(total-need):(need-total);
	for(int i = 1; i<=MaxClients; i++){
		if(num<=0) return;
		if(kick){
			if(isBot(i)){
				KickClient(i);
				num--;
			}
		}else if(isPlayer(i) && isSurvivor(i)){
			float Origin[3];
			GetClientAbsOrigin(i, Origin);
			do{
				int botNo = CreateFakeClient("Bot");
				if(!isVaild(botNo)) SetFailState("Error in CreateBot");
				ChangeClientTeam(botNo, TEAM_SURVIVOR);
				DispatchKeyValue(botNo, "classname", "SurvivorBot");
				DispatchSpawn(botNo);
				if(!IsPlayerAlive(botNo)) SDKCall(hRespawn, botNo);
				TeleportEntity(botNo, Origin, NULL_VECTOR, NULL_VECTOR);
				KickClient(botNo);
			} while(--num);
		}
	}
}

public Action Cmd_Spawn(int client, int args){
	if(isVaildPlayer(client)) SDKCall(hRespawn, client);
	return Plugin_Handled;
}

void TakeOverBot(client, bot){
	SDKCall(hSpec, bot, client);
	SDKCall(hSwitch, client, true);
}

void Join(int client){
	for(int i = 1; i<=MaxClients; i++){
		if(isBot(i) && IsPlayerAlive(i)){
			char classname[12];
			GetEntityNetClass(i, classname, 12);
			if(StrEqual(classname, "SurvivorBot")){
				//int sid = GetClientOfUserId(GetEntProp(i, Prop_Send, "m_humanSpectatorUserID"));
				//PrintToChatAll("sid %i client %i", sid, client);
				//if(sid!=client) continue;
				TakeOverBot(client, i);
				return;
			}
		}
	}
	PrintToChat(client, "\x05[加入失败] \x04没有可接管的Bot");
}

int Count(Type fiter){
	int num = 0;
	for(int i = 1; i<=MaxClients; i++){
		if(!IsClientInGame(i)) continue;
		int t = GetClientTeam(i);
		switch(fiter){
			case Bot:
				if(t==TEAM_SURVIVOR && IsFakeClient(i)) num++;
			case Survivor:
				if(t==TEAM_SURVIVOR) num++;
			case Spectator:
				if(t==TEAM_SPECTATOR) num++;
			case Player:
				if(!IsFakeClient(i)) num++;
		}
	}
	return num;
}