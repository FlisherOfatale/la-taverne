-- luacheck config (https://github.com/lunarmodules/luacheck). Run from the repo root: luacheck LaTaverne
-- The game runs Lua 5.1. A global not listed here is reported: check it's a real game global
-- (or a real one from an addon we read) before adding it, a typo shows up the same way.
std = "lua51"
max_line_length = false
exclude_files = { "LaTaverne/Libs/" }

ignore = {
    "212",       -- unused argument (event and callback signatures)
    "211/ADDON", -- every file starts with `local ADDON, ns = ...`
    "431",       -- shadowing an upvalue (style)
    "432",       -- shadowing an upvalue argument (style)
    "542",       -- empty if branch (used with a comment to spell out a case)
}

-- Globals the addon sets.
globals = {
    "LaTaverneDB",
    "SLASH_LATAVERNE1", "SlashCmdList",
    "BINDING_HEADER_LATAVERNE", "BINDING_NAME_LATAVERNE_TOGGLE", "BINDING_NAME_LATAVERNE_WAITING",
    "LaTaverne_Toggle", "LaTaverne_ShowWaiting",
    "WorldMapFrame", -- its pinPools gets our pool
}

-- Globals the addon reads: the game's API and UI, and the addons it works with.
read_globals = {
    -- Lua helpers the game adds
    "format", "date", "time", "strsplit", "strtrim", "tinsert", "tremove", "wipe",
    "debugstack", "geterrorhandler", "seterrorhandler", "hooksecurefunc", "issecretvalue",
    "CopyTable", "Mixin", "CreateFromMixins", "RunNextFrame",

    -- Namespaces
    "C_AddOns", "C_BattleNet", "C_ChatInfo", "C_ClassColor", "C_Club", "C_EventUtils",
    "C_FriendList", "C_GuildInfo", "C_Item", "C_LFGList", "C_Map", "C_PartyInfo",
    "C_RestrictedActions", "C_Texture", "C_Timer", "C_XMLUtil", "Enum", "EventRegistry",
    "Settings", "MenuUtil", "ScrollUtil", "ScrollBoxConstants", "InputUtil", "ChatFrameUtil",

    -- Functions
    "Ambiguate", "BetterDate", "CanEditGuildInfo", "CanViewOfficerNote",
    "ChatFrame_AddMessageEventFilter", "ChatFrame_MessageEventHandler", "ChatFrame_OnEvent",
    "ChatFrame_RemoveChannel", "ChatFrame_SendTell", "ClearOverrideBindings",
    "CreateAtlasMarkup", "CreateDataProvider", "CreateFrame", "CreateFramePool",
    "CreateScrollBoxListLinearView", "CreateUnsecuredRegionPoolInstance", "CreateVector2D",
    "FlashClientIcon", "GameTooltip_AddErrorLine", "GameTooltip_Hide", "GameTooltip_SetTitle",
    "GetAddOnMetadata", "GetBindingKey", "GetBindingText", "GetBuildInfo", "GetCVar",
    "GetCVarBool", "GetChannelDisplayInfo", "GetChannelName", "GetChatTimestampFormat",
    "GetChatWindowInfo", "GetCurrentBindingSet", "GetCurrentKeyBoardFocus", "GetCursorPosition",
    "GetFramesRegisteredForEvent", "GetGuildEventInfo", "GetGuildInfo", "GetGuildInfoText",
    "GetGuildRosterInfo", "GetGuildRosterLastOnline", "GetGuildRosterShowOffline", "GetItemInfo",
    "GetLocale", "GetNormalizedRealmName", "GetNumDisplayChannels", "GetNumGroupMembers",
    "GetNumGuildEvents", "GetNumGuildMembers", "GetPlayerLink", "GetRealmName", "GetServerTime",
    "GetSubZoneText", "GetTime", "GetUnitName", "GetZoneText", "GuildControlGetNumRanks",
    "GuildControlGetRankName", "GuildRoster", "InCombatLockdown", "InterfaceOptions_AddCategory",
    "InviteUnit", "IsAddOnLoaded", "IsAltKeyDown", "IsControlKeyDown", "IsInGroup", "IsInGuild",
    "IsInInstance", "IsInRaid", "IsMouseButtonDown", "IsResting", "IsShiftKeyDown",
    "JoinTemporaryChannel", "LeaveChannelByName", "PlaySound", "QueryGuildEventLog", "ReloadUI",
    "SaveBindings", "SendChatMessage", "SendWho", "SetBinding", "SetItemRef",
    "SetOverrideBindingClick", "SetPortraitToTexture", "StaticPopup_Hide",
    "UIDropDownMenu_Initialize", "UninviteUnit", "UnitAffectingCombat", "UnitClass",
    "UnitExists", "UnitFactionGroup", "UnitFullName", "UnitGUID", "UnitGroupRolesAssigned",
    "UnitInParty", "UnitInRaid", "UnitIsAFK", "UnitIsFriend", "UnitIsGroupAssistant",
    "UnitIsGroupLeader", "UnitIsPlayer", "UnitIsUnit", "UnitLevel", "UnitName",
    "ButtonFrameTemplate_HideAttic", "ButtonFrameTemplate_HideButtonBar",
    "ButtonFrameTemplate_HidePortrait", "ButtonFrameTemplate_ShowAttic",
    "ButtonFrameTemplate_ShowPortrait",

    -- Frames, mixins and fonts
    "AddonCompartmentFrame", "BackdropTemplateMixin", "ChatFontNormal", "ChatFrame1",
    "ChatFrameMixin", "DEFAULT_CHAT_FRAME", "FriendsFrame", "GameFontHighlight", "GameTooltip",
    "InputIconTextureSetUtility", "MapCanvasDataProviderMixin", "MapCanvasPinMixin", "UIParent",
    "UISpecialFrames",

    -- Constants and strings
    "CANCEL", "CHAT_GUILD_GET", "CHAT_TIMESTAMP_FORMAT", "CLASS_ICON_TCOORDS", "ChatTypeInfo",
    "ERR_ALREADY_IN_GROUP_S", "ERR_DECLINE_GROUP_S", "GUILD", "ITEM_QUALITY_COLORS", "LEVEL",
    "LE_PARTY_CATEGORY_HOME", "MAX_WOW_CHAT_CHANNELS", "NUM_CHAT_WINDOWS", "QuestDifficultyColors",
    "RAID_CLASS_COLORS", "SOUNDKIT", "UNKNOWNOBJECT",

    -- Libraries and the addons we work with
    "LibStub", "BugGrabber", "OpenMapAPI", "OpenMapDB",
}
