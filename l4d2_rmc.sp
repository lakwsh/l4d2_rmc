#include <dhooks>
#include <sdktools>
#include <sourcemod>

#define TEAM_SPECTATOR 1
#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

#define isBot(%1) (IsClientInGame(%1) && IsFakeClient(%1))
#define isPlayer(%1) (IsClientInGame(%1) && !IsFakeClient(%1))
#define isSpectator(%1) (GetClientTeam(%1) == TEAM_SPECTATOR)
#define isSurvivor(%1) (GetClientTeam(%1) == TEAM_SURVIVOR)
#define isAdmin(%1) GetAdminFlag(GetUserAdmin(%1), Admin_Generic)

Handle hCreate, hSpec, hSwitch, hRespawn, hGoAway;
ConVar cCanAway, cAwayMode, cCanRespawn, cCanTeleport, cDefaultSlots, cMultMed, cRecovery, cUpdateMax, cMultHp, cTankHp;
bool Enable = false, CanAway, CanTeleport, CanRespawn;
int DefaultSlots, plList[32][3];  // ArrayStack

enum Fiter_Type {
	Survivor,
	Player,
	Bot
};

enum Save_Key {
	i_Id = 0,
	i_Hp,
	i_Rev
}

public Plugin myinfo = {
	name = "[L4D2] Multiplayer",
	description = "L4D2 Multiplayer Plugin",
	author = "lakwsh",
	version = "2.2.1",
	url = "https://github.com/lakwsh/l4d2_rmc"
};

public void OnPluginStart() {
	ConVar cMax = FindConVar("sv_maxplayers");
	if(!cMax) SetFailState("L4DToolZ not found!");
	cMax.AddChangeHook(OnEnableChanged);

	GameData hGameData = new GameData("l4d2_rmc");
	if(!hGameData) SetFailState("Failed to load 'l4d2_rmc.txt' gamedata.");

	StartPrepSDKCall(SDKCall_Static);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CreatePlayerBot")) SetFailState("Failed to find signature: CreatePlayerBot");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	hCreate = EndPrepSDKCall();
	if(!hCreate) SetFailState("CreateBot Signature broken.");

	StartPrepSDKCall(SDKCall_Player);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SetHumanSpec")) SetFailState("Failed to find signature: SetHumanSpec");
	PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	hSpec = EndPrepSDKCall();
	if(!hSpec) SetFailState("Spectator Signature broken.");

	StartPrepSDKCall(SDKCall_Player);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "TakeOverBot")) SetFailState("Failed to find signature: TakeOverBot");
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	hSwitch = EndPrepSDKCall();
	if(!hSwitch) SetFailState("TakeOver Signature broken.");

	StartPrepSDKCall(SDKCall_Player);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "RoundRespawn")) SetFailState("Failed to find signature: Respawn");
	hRespawn = EndPrepSDKCall();
	if(!hRespawn) SetFailState("Respawn Signature broken.");

	StartPrepSDKCall(SDKCall_Player);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "GoAwayFromKeyboard")) SetFailState("Failed to find signature: GoAwayFromKeyboard");
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	hGoAway = EndPrepSDKCall();
	if(!hGoAway) SetFailState("GoAwayFromKeyboard Signature broken.");

	DHookSetup hDetour = DHookCreateFromConf(hGameData, "HibernationUpdate");
	if(!hDetour || !DHookEnableDetour(hDetour, true, OnHibernationUpdate)) SetFailState("Failed to hook HibernationUpdate");

	CloseHandle(hGameData);

	HookEvent("bot_player_replace", OnTakeOver);
	HookEvent("player_bot_replace", OnPlayerAfk, EventHookMode_Pre);
	HookEvent("round_end", OnRoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_activate", OnActivate);
	HookEvent("player_disconnect", OnPlayerDisconnect, EventHookMode_Pre);

	RegConsoleCmd("sm_jg", Cmd_Join);
	RegConsoleCmd("sm_away", Cmd_Away);
	RegConsoleCmd("sm_zs", Cmd_Kill);
	RegConsoleCmd("sm_setmax", Cmd_SetMax);
	RegConsoleCmd("sm_info", Cmd_Info);
	RegConsoleCmd("sm_fh", Cmd_Respawn);
	RegConsoleCmd("sm_tp", Cmd_Teleport);

	cCanAway = CreateConVar("rmc_away", "1", "允许非管理员使用!away加入观察者", 0, true, 0.0, true, 1.0);
	cAwayMode = CreateConVar("rmc_awaymode", "0", "加入观察者类型 0=切换阵营模式 1=普通模式", 0, true, 0.0, true, 1.0);
	cCanRespawn = CreateConVar("rmc_fh", "0", "允许非管理员使用!fh指令复活", 0, true, 0.0, true, 1.0);
	cCanTeleport = CreateConVar("rmc_tp", "0", "允许非管理员使用!tp指令传送Bot", 0, true, 0.0, true, 1.0);
	cDefaultSlots = CreateConVar("rmc_defaultslots", "4", "默认玩家数", 0, true, 1.0, true, 16.0);
	cMultMed = CreateConVar("rmc_multmed", "1", "是否开启多倍药物功能", 0, true, 0.0, true, 1.0);
	cMultHp = CreateConVar("rmc_multhp", "1", "是否开启坦克多倍血量", 0, true, 0.0, true, 1.0);
	cRecovery = CreateConVar("rmc_recovery", "1", "是否开启重复进服恢复血量功能", 0, true, 0.0, true, 1.0);
	cUpdateMax = CreateConVar("rmc_updatemax", "1", "是否开启自动设置客户端数功能", 0, true, 0.0, true, 1.0);
	AutoExecConfig(true, "l4d2_rmc");

	SetConVarBounds(FindConVar("survivor_limit"), ConVarBound_Upper, true, 16.0);
	SetConVarBounds(FindConVar("z_max_player_zombies"), ConVarBound_Upper, true, 16.0);
	cTankHp = FindConVar("z_tank_health");

	DefaultSlots = cDefaultSlots.IntValue;
	cMax.IntValue = DefaultSlots == 4 ? -1 : DefaultSlots;
}

public void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	Enable = StringToInt(newValue) != -1;
}

public void OnMapStart() {
	CanAway = GetConVarBool(cCanAway);
	CanRespawn = GetConVarBool(cCanRespawn);
	CanTeleport = GetConVarBool(cCanTeleport);
	DefaultSlots = cDefaultSlots.IntValue;
	plList[0][i_Id] = 0;  // reset
}

public void OnRoundEnd(Event event, const char[] name, bool dontBroadcast) {
	plList[0][i_Id] = 0;  // reset
}

public MRESReturn OnHibernationUpdate(DHookParam hParams) {
	if(!Enable || !DHookGetParam(hParams, 1)) return MRES_Ignored;
	PrintToServer("[DEBUG] 重置人数设置...");
	if(cUpdateMax.IntValue == 1) ServerCommand("sv_setmax 18");
	FindConVar("sv_maxplayers").IntValue = DefaultSlots == 4 ? -1 : DefaultSlots;
	ResetConVar(cTankHp, true);
	return MRES_Handled;
}

public void OnPlayerAfk(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(GetEventInt(event, "player", 0));
	if(!client || !isPlayer(client) || !isSurvivor(client)) return;  // 创建bot会触发
	int i = 0;
	for(; i < sizeof(plList) - 1 && plList[i][i_Id]; i++) {
	}  // count
	for(int j = i; j > 0; j--) {
		for(int k = 0; k < 3; k++) {  // Save_Key
			plList[j][k] = plList[j - 1][k];
		}
	}
	plList[0][i_Id] = GetSteamAccountID(client);
	if(IsPlayerAlive(client)) {
		plList[0][i_Hp] = GetClientHealth(client);
		plList[0][i_Rev] = GetEntProp(client, Prop_Send, "m_currentReviveCount");  // FIXME: 倒地状态血量
	} else {
		plList[0][i_Hp] = 0;
		plList[0][i_Rev] = 0;
	}
	PrintToServer("[DEBUG] 保存数据 id[%d] hp[%d] rev[%d]", plList[0][i_Id], plList[0][i_Hp], plList[0][i_Rev]);
}

public void OnTakeOver(Event event, const char[] name, bool dontBroadcast) {
	if(!Enable || cRecovery.IntValue != 1) return;
	int client = GetClientOfUserId(GetEventInt(event, "player", 0));
	if(!client || !isSurvivor(client)) return;
	int id = GetSteamAccountID(client);
	if(!id) {
		ForcePlayerSuicide(client);
		PrintToChat(client, "\x05[提示] \x04无法验证steamid,默认死亡状态");
		return;
	}
	for(int j = 0; j < sizeof(plList) && plList[j][i_Id]; j++) {  // 注意round_end
		if(plList[j][i_Id] == id) {
			PrintToServer("[DEBUG] id[%d] hp[%d] rev[%d]", plList[j][i_Id], plList[j][i_Hp], plList[j][i_Rev]);
			int flag = 0;
			if(GetClientHealth(client) > plList[j][i_Hp]) {
				if(!plList[j][i_Hp]) ForcePlayerSuicide(client);
				else SetEntityHealth(client, plList[j][i_Hp]);
				flag |= 1;
			}
			if(GetEntProp(client, Prop_Send, "m_currentReviveCount") < plList[j][i_Rev]) {
				SetEntProp(client, Prop_Send, "m_currentReviveCount", plList[j][i_Rev]);
				flag |= 2;
			}
			if(flag) PrintToChatAll("\x05[提示] \x03%N \x04重复接管Bot, %s%s%s", client, flag & 1 ? "恢复血量" : "", flag == 3 ? "及" : (flag & 2 ? "恢复" : ""), flag & 2 ? "倒地次数" : "");
			return;
		}
	}
}

public void OnPlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
	if(!Enable) return;
	int client = GetClientOfUserId(GetEventInt(event, "userid", 0));
	if(client && isPlayer(client)) CheckSlots(true);
}

public void OnActivate(Event event, const char[] name, bool dontBroadcast) {
	int uid = GetEventInt(event, "userid", 0);
	int client = GetClientOfUserId(uid);
	if(client && isPlayer(client)) {
		if(Enable) CheckSlots();
		CreateTimer(2.5, JoinTeam, uid, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action JoinTeam(Handle timer, any uid) {
	int client = GetClientOfUserId(uid);
	if(client && isPlayer(client)) {
		PrintToChat(client, "\x04[提示] \x01多人插件:\x05 %s", Enable ? "开启" : "关闭");
		PrintToChat(client, "\x05[指令] \x03!setmax \x04修改人数上限, \x03!zs \x04自杀");
		PrintToChat(client, "\x05[指令] \x03!jg \x04加入生还者, \x03!away \x04加入观察者");
		if(Enable) {
			PrintToChat(client, "\x04[提示] \x01多倍药物:\x05 %s, \x01Tank多倍血量:\x05 %s", cMultMed.IntValue ? "已开启" : "已关闭", GetConVarInt(cMultHp) ? "已开启" : "已关闭");
			if(isSpectator(client)) Join(client);
		}
	}
	return Plugin_Stop;
}

public Action Cmd_SetMax(int client, int args) {
	if(args != 1) {
		ReplyToCommand(client, "!setmax <人数>");
		return Plugin_Handled;
	}
	if(IsVoteInProgress()) {
		ReplyToCommand(client, "投票进行中");
		return Plugin_Handled;
	}
	char tmp[3];
	GetCmdArg(1, tmp, sizeof(tmp));
	int max = StringToInt(tmp);
	if(max < 1 || max > 16) max = DefaultSlots;
	if(!client || isAdmin(client)) {  // console
		SetMax(max);
	} else {
		IntToString(max, tmp, sizeof(tmp));
		Menu vote = new Menu(voteCallback, MenuAction_VoteEnd);
		vote.SetTitle("修改人数上限为%d", max);
		vote.AddItem(tmp, "Yes");			// 0
		vote.AddItem("###MAX_NO###", "No");  // 1
		vote.ExitButton = false;
		vote.DisplayVoteToAll(20);
	}
	return Plugin_Handled;
}

public int voteCallback(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_VoteEnd) {
		int votes, totalVotes;
		GetMenuVoteInfo(param2, votes, totalVotes);
		if(param1 == 1 || votes != totalVotes) {
			PrintToChatAll("\x05[提示]\x01 投票未全票通过,修改失败");
			return 0;
		}
		char tmp[14], dsp[16];
		menu.GetItem(0, tmp, sizeof(tmp), _, dsp, sizeof(dsp));
		int max = StringToInt(tmp);
		SetMax(max);
	}
	return 0;
}

public Action Cmd_Info(int client, int args) {
	ReplyToCommand(client, "Player=%d Bot=%d Survivor=%d", Count(Player), Count(Bot), Count(Survivor));
	return Plugin_Handled;
}

void SetMax(int max) {
	FindConVar("sv_maxplayers").IntValue = max;
	if(Count(Player) >= DefaultSlots) ServerCommand("sv_cookie 0");
	CheckSlots();
	PrintToChatAll("\x05[提示]\x01 已修改人数上限为%d人", max);
}

void SetEntCount(const char[] ent, int count) {
	int idx = FindEntityByClassname(-1, ent);
	while(idx != -1) {
		DispatchKeyValueInt(idx, "count", count);
		idx = FindEntityByClassname(idx, ent);
	}
}

void SetMultMed(int slots) {
	int mult = (slots - 1) / 4 + 1;
	//SetEntCount("weapon_defibrillator_spawn", mult);	// 电击器
	//SetEntCount("weapon_first_aid_kit_spawn", mult);	// 医疗包
	SetEntCount("weapon_pain_pills_spawn", mult);		// 止痛药
	//SetEntCount("weapon_adrenaline_spawn", mult);		// 肾上腺素
	//SetEntCount("weapon_molotov_spawn", mult);		// 燃烧瓶
	//SetEntCount("weapon_vomitjar_spawn", mult);		// 胆汁罐
	//SetEntCount("weapon_pipe_bomb_spawn", mult);		// 土制炸弹
}

// 规则1: 设=实						=> 不处理
// 规则2: 实>设						=> 设
// 规则3: 设>def && 设>实 && def>实	=> def
// 规则4: 设>def && 设>实 && 实>def	=> 实
// 规则5: def>设					=> 设
void CheckSlots(bool disconnect = false) {
	int max = FindConVar("sv_maxplayers").IntValue;
	if(max < 1) max = DefaultSlots;
	int total = max;
	if(Count(Survivor) != max) {  // 1
		int now = Count(Player);
		if(disconnect) now--;
		if(DefaultSlots >= max) {
			// 5
		} else if(now > max) {
			// 2
		} else {
			if(DefaultSlots > now) total = DefaultSlots;  // 3
			else total = now;							 // 4
		}
		BotControl(total);
	}
	if(total > 4) {
		if(cMultMed.IntValue == 1) SetMultMed(total);
		if(cMultHp.IntValue == 1) {
			int hp = total * 1000;
			int flag = GetCommandFlags("z_tank_health");
			SetCommandFlags("z_tank_health", flag & ~FCVAR_CHEAT);
			cTankHp.IntValue = hp;  // 无需处理游戏难度
			SetCommandFlags("z_tank_health", flag);
		}
	}
	if(total > 8 && cUpdateMax.IntValue == 1) ServerCommand("sv_setmax 31");
	int pl = Count(Player);
	FindConVar("survivor_limit").IntValue = max > pl ? max : pl;  // 会踢出bot
	FindConVar("z_max_player_zombies").IntValue = total;		  // 对抗-特感人数
}

public Action Cmd_Join(int client, int args) {
	if(client && isPlayer(client)) {
		if(isSpectator(client)) Join(client);
		else PrintToChat(client, "\x05[加入失败] \x04请先加入观察者阵营");
	}
	return Plugin_Handled;
}

public Action Cmd_Kill(int client, int args) {
	if(client && isPlayer(client)) {
		if(IsPlayerAlive(client)) {
			ForcePlayerSuicide(client);
			char name[32];
			GetClientName(client, name, 32);
			PrintToChatAll("\x05[提示] \x04%s \x05升天了...", name);
		} else PrintToChat(client, "\x05[迷惑] \x04自杀? 你也配?");
	}
	return Plugin_Handled;
}

public Action Cmd_Away(int client, int args) {
	if(client && isPlayer(client)) {
		if(!CanAway && !GetUserFlagBits(client)) {
			PrintToChat(client, "\x05[失败] \x04你无权使用!away指令");
			return Plugin_Handled;
		}
		if(GetConVarBool(cAwayMode)) SDKCall(hGoAway, client);
		else ChangeClientTeam(client, TEAM_SPECTATOR);
	}
	return Plugin_Handled;
}

public Action Cmd_Respawn(int client, int args) {
	if(client && isPlayer(client) && !IsPlayerAlive(client)) {
		if(!CanRespawn && !GetAdminFlag(GetUserAdmin(client), Admin_Cheats)) {
			PrintToChat(client, "\x05[失败] \x04你无权使用!fh指令");
			return Plugin_Handled;
		}
		SDKCall(hRespawn, client);
		for(int i = 1; i <= MaxClients; i++) {
			if(i != client && isPlayer(i) && IsPlayerAlive(i)) {
				float Origin[3];
				GetClientAbsOrigin(i, Origin);
				TeleportEntity(client, Origin, NULL_VECTOR, NULL_VECTOR);
				break;
			}
		}
	}
	return Plugin_Handled;
}

public Action Cmd_Teleport(int client, int args) {
	if(client && isPlayer(client) && isSurvivor(client) && IsPlayerAlive(client)) {
		if(!CanTeleport && !GetAdminFlag(GetUserAdmin(client), Admin_Cheats)) {
			PrintToChat(client, "\x05[失败] \x04你无权使用!tp指令");
			return Plugin_Handled;
		}
		float Origin[3];
		GetClientAbsOrigin(client, Origin);
		for(int i = 1; i <= MaxClients; i++) {
			if(isBot(i) && isSurvivor(i) && IsPlayerAlive(i)) {
				TeleportEntity(i, Origin, NULL_VECTOR, NULL_VECTOR);
			}
		}
	}
	return Plugin_Handled;
}

void BotControl(int need) {
	int total = Count(Survivor);
	if(!need || need == total) return;
	PrintToServer("[DEBUG] need=%d survivor=%d", need, total);
	bool kick = total > need;
	int num = kick ? (total - need) : (need - total);
	for(int i = 1; i <= MaxClients; i++) {
		if(num <= 0) return;
		if(kick) {
			if(isBot(i) && isSurvivor(i)) {
				KickClient(i);
				num--;
			}
		} else if(isPlayer(i) && isSurvivor(i)) {
			float Origin[3];
			GetClientAbsOrigin(i, Origin);
			do {
				int botNo = SDKCall(hCreate, "SurvivorBot");
				if(!botNo) {
					PrintToServer("Error in CreateBot");
					break;
				}
				ChangeClientTeam(botNo, TEAM_SURVIVOR);
				TeleportEntity(botNo, Origin, NULL_VECTOR, NULL_VECTOR);
			} while(--num);
		}
	}
}

bool IsClientDead(int client, bool ignore = true) {
	int id = GetSteamAccountID(client);
	if(!id) return !ignore;
	for(int j = 0; j < sizeof(plList) && plList[j][i_Id]; j++) {
		if(plList[j][i_Id] == id) return !plList[j][i_Hp];
	}
	return false;
}

bool TakeOverBot(int client, int bot) {
	SDKCall(hSpec, bot, client);
	return SDKCall(hSwitch, client, true);
}

void Join(int client) {
	if(IsClientDead(client)) {
		PrintToChat(client, "\x05[加入失败] \x04当前为死亡状态");
		return;
	}
	for(int i = 1; i <= MaxClients; i++) {
		if(isBot(i) && IsPlayerAlive(i)) {
			char classname[12];
			GetEntityNetClass(i, classname, 12);
			if(StrEqual(classname, "SurvivorBot") && TakeOverBot(client, i)) return;
		}
	}
	PrintToChat(client, "\x05[加入失败] \x04没有可接管的Bot");
}

int Count(Fiter_Type fiter) {
	int num = 0;
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsClientInKickQueue(i)) continue;
		int t = GetClientTeam(i);
		switch(fiter) {
			case Survivor:
				if(t == TEAM_SURVIVOR) num++;
			case Player:
				if(!IsFakeClient(i)) num++;
			case Bot:
				if(IsFakeClient(i) && t == TEAM_SURVIVOR) num++;
		}
	}
	return num;
}