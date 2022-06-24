#include <sourcemod>
#include <sdktools>

#define TEAM_SPECTATOR	1
#define TEAM_SURVIVOR	2
#define TEAM_INFECTED	3

#define isValid(%1)			(%1>0 && %1<=MaxClients)
#define isBot(%1)			(IsClientInGame(%1) && IsFakeClient(%1))
#define isPlayer(%1)		(IsClientInGame(%1) && !IsFakeClient(%1))
#define isValidPlayer(%1)	(isValid(%1) && isPlayer(%1))
#define isSpectator(%1)		GetClientTeam(%1)==TEAM_SPECTATOR
#define isSurvivor(%1)		GetClientTeam(%1)==TEAM_SURVIVOR
#define isAdmin(%1)			GetUserAdmin(%1)!=INVALID_ADMIN_ID

Handle hSpec = INVALID_HANDLE, hSwitch = INVALID_HANDLE, hRespawn = INVALID_HANDLE, hGoAway = INVALID_HANDLE;
ConVar cMax, cCanAway, cAwayMode, cDefaultSlots;
bool Enable = false, CanAway, Reconnect = false;
int DefaultSlots, plList[32][2];

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
	version = "1.8.4_beta1",
	url = "https://github.com/lakwsh/l4d2_rmc"
};

public void OnPluginStart(){
	cMax = FindConVar("sv_maxplayers");
	if(cMax==INVALID_HANDLE) SetFailState("L4DToolZ not found!");
	cMax.AddChangeHook(OnEnableChanged);

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

	HookEvent("round_start", OnRoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", OnPlayerSpawn, EventHookMode_PostNoCopy);
	HookEvent("player_activate", OnActivate, EventHookMode_PostNoCopy);

	RegConsoleCmd("sm_jg", Cmd_Join);
	RegConsoleCmd("sm_away", Cmd_Away);
	RegConsoleCmd("sm_zs", Cmd_Kill);
	RegConsoleCmd("sm_info", Cmd_ShowInfo);
	RegConsoleCmd("sm_setmax", Cmd_SetMax);
	RegAdminCmd("sm_fh", Cmd_Spawn, ADMFLAG_CHEATS, "复活");
	RegAdminCmd("sm_kb", Cmd_KickBot, ADMFLAG_KICK, "强制踢出机器人");
	RegAdminCmd("sm_sb", Cmd_SetBot, ADMFLAG_KICK, "设置生还者人数");

	cCanAway = CreateConVar("rmc_away", "1", "允许非管理员使用!away加入观察者", 0, true, 0.0, true, 1.0);
	cAwayMode = CreateConVar("rmc_awaymode", "0", "加入观察者类型 0=切换阵营模式 1=普通模式", 0, true, 0.0, true, 1.0);
	cDefaultSlots = CreateConVar("rmc_defaultslots", "4", "默认玩家数", 0, true, 1.0, true, 16.0);
	AutoExecConfig(true, "l4d2_rmc");

	SetConVarBounds(FindConVar("survivor_limit"), ConVarBound_Upper, true, 16.0);
	SetConVarBounds(FindConVar("z_max_player_zombies"), ConVarBound_Upper, true, 16.0);

	DefaultSlots = GetConVarInt(cDefaultSlots);
	SetConVarInt(cMax, DefaultSlots==4?-1:DefaultSlots);
}

public void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue){
	Enable = StringToInt(newValue)!=-1;
}

public void OnMapStart(){
	CanAway = GetConVarBool(cCanAway);
	DefaultSlots = GetConVarInt(cDefaultSlots);
	plList[0][0] = 0;	// reset
}

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast){
	Reconnect = true;
}

public void OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast){
	Reconnect = false;
}

//public void OnFinaleWin(Event event, const char[] name, bool dontBroadcast){
//	SetConVarInt(cMax, -1);	// reset
//}

public void OnActivate(Event event, const char[] name, bool dontBroadcast){
	int uid = GetEventInt(event, "userid", 0);
	int client = GetClientOfUserId(uid);
	if(isValidPlayer(client)){
		if(Enable) CheckSlots();
		CreateTimer(2.5, JoinTeam, uid, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action JoinTeam(Handle timer, any uid){
	int client = GetClientOfUserId(uid);
	if(isValidPlayer(client)){
		PrintToChat(client, "\x04[提示] \x01多人插件:\x05 %s", Enable?"开启":"关闭");
		PrintToChat(client, "\x05[说明] \x03!setmax \x04修改人数上限, \x03!info \x04显示人数信息");
		PrintToChat(client, "\x05[说明] \x03!jg \x04加入生还者, \x03!away \x04加入观察者, \x03!kb \x04踢出机器人");
		if(Enable){
			Cmd_ShowInfo(client, 0);
			if(isSpectator(client)) Join(client);
			CreateTimer(1.0, UpdateHealth, uid, TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	return Plugin_Stop;
}

public Action UpdateHealth(Handle timer, any uid){
	int client = GetClientOfUserId(uid);
	if(isValidPlayer(client) && isSurvivor(client)){
		int id = GetSteamAccountID(client);
		if(!id){
			ForcePlayerSuicide(client);
			PrintToChat(client, "\x05[提示] \x04无法验证steamid,默认死亡状态");
		}else{
			for(int j = 0; j<sizeof(plList) && plList[j][0]; j++){
				if(plList[j][0]==id){
					if(GetClientHealth(client)<plList[j][1]) break;
					switch(plList[j][1]){
						case -1: return Plugin_Stop;
						case 0: ForcePlayerSuicide(client);
						default: SetEntityHealth(client, plList[j][1]);
					}
					PrintToChatAll("\x05[提示] \x04检测到 \x03%N \x04重复进服,恢复上次血量", client);
					break;
				}
			}
		}
	}
	return Plugin_Stop;
}

public Action Cmd_SetMax(int client, int args){
	if(args==1){
		char tmp[3];
		GetCmdArg(1, tmp, sizeof(tmp));
		int max = StringToInt(tmp);
		if(max<1 || max>16) max = DefaultSlots;
		if(!client || isAdmin(client)){	// console
			setMax(max);
		}else{
			if(IsVoteInProgress()){
				PrintToChatAll("\x05[提示]\x01 投票进行中,无法修改人数上限");
				return Plugin_Handled;
			}
			Menu vote = new Menu(voteCallback, MenuAction_VoteEnd);
			vote.SetTitle("修改人数上限为%d", max);
			vote.AddItem(tmp, "Yes");	// 0
			vote.AddItem("###RMC_NO###", "No");	// 1
			vote.ExitButton = false;
			vote.DisplayVoteToAll(20);
		}
	}
	return Plugin_Handled;
}

public int voteCallback(Menu menu, MenuAction action, int param1, int param2){
	if(action==MenuAction_VoteEnd){
		int votes, totalVotes;
		GetMenuVoteInfo(param2, votes, totalVotes);
		if(param1==1 || votes!=totalVotes){
			PrintToChatAll("\x05[提示]\x01 投票未全票通过,人数上限未修改");
		}else{
			char item[PLATFORM_MAX_PATH], display[64];
			menu.GetItem(0, item, sizeof(item), _, display, sizeof(display));
			setMax(StringToInt(item));
		}
	}
	return 0;
}

void setMax(int max){
	SetConVarInt(cMax, max==4?-1:max);
	if(max!=4) CheckSlots();	// unreserved
	PrintToChatAll("\x05[提示]\x01 已修改人数上限为%d人", max);
}

public void OnClientDisconnect(client){
	if(Enable && !Reconnect && !IsFakeClient(client)){
		int i = 0;
		for(; i<sizeof(plList)-1 && plList[i][0]; i++){}	// count
		for(int j = i; j>0; j--){
			plList[j][0] = plList[j-1][0];
			plList[j][1] = plList[j-1][1];
		}
		plList[0][0] = GetSteamAccountID(client);
		if(IsClientInGame(client) && isSurvivor(client)){	// TODO: 倒地次数
			if(IsPlayerAlive(client)) plList[0][1] = GetClientHealth(client);
			else plList[0][1] = 0;
		}
		else plList[0][1] = -1;
		CheckSlots();
	}
}

void CheckSlots(){
	if(Reconnect) return;
	int max = GetConVarInt(cMax), player = Count(Player);
	if(Count(Survivor)>max) BotControl(max);

	if(max>DefaultSlots && player>=DefaultSlots){
		ServerCommand("sv_unreserved");
		BotControl(player);
	}else ServerCommand("sv_setmax 18");

	int total = Count(Survivor);
	if(!total) return;
	if(total>8) ServerCommand("sv_setmax 31");
	SetConVarInt(FindConVar("survivor_limit"), max);	// 会踢出bot
	SetConVarInt(FindConVar("z_max_player_zombies"), total);
}

public Action Cmd_KickBot(int client, int args){
	BotControl(0);
	PrintToChatAll("\x05[提示]\x01 已踢出所有机器人");
	return Plugin_Handled;
}

public Action Cmd_SetBot(int client, int args){
	if(args==1){
		char tmp[3];
		GetCmdArg(1, tmp, sizeof(tmp));
		BotControl(StringToInt(tmp));
	}
	return Plugin_Handled;
}

public Action Cmd_Join(int client, int args){
	if(isValidPlayer(client)){
		if(isSpectator(client)) Join(client);
		else PrintToChat(client, "\x05[加入失败] \x04请先加入观察者阵营");
	}
	return Plugin_Handled;
}

public Action Cmd_Kill(int client, int args){
	if(isValidPlayer(client)){
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

public Action Cmd_Spawn(int client, int args){
	if(!isValidPlayer(client) || IsPlayerAlive(client)) return Plugin_Handled;
	SDKCall(hRespawn, client);
	for(int i = 1; i<=MaxClients; i++){
		if(i!=client && isPlayer(i) && IsPlayerAlive(i)){
			float Origin[3];
			GetClientAbsOrigin(i, Origin);
			TeleportEntity(client, Origin, NULL_VECTOR, NULL_VECTOR);
			break;
		}
	}
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
				if(!isValid(botNo)) SetFailState("Error in CreateBot");
				ChangeClientTeam(botNo, TEAM_SURVIVOR);
				DispatchKeyValue(botNo, "classname", "SurvivorBot");
				DispatchSpawn(botNo);
				if(!IsPlayerAlive(botNo)){
					SDKCall(hRespawn, botNo);
					SetEntityHealth(botNo, 50);
				}
				TeleportEntity(botNo, Origin, NULL_VECTOR, NULL_VECTOR);
				KickClient(botNo);
			} while(--num);
		}
	}
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