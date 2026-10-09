-- Inviter Escarlate - WoW 3.3.5a (Interface 30300)
-- Configuracao em: Esc > Interface > AddOns > Inviter Escarlate
-- /ie        abre o painel de configuracao
-- /ie on|off liga/desliga o auto-invite
-- /ie notas  lista quem pediu para alterar a nota (/ie notas limpar apaga)
-- /ie spec   mostra a sua funcao; /ie spec tank|heal|dps fixa, /ie spec auto volta ao automatico
-- /ie anuncios inicia/para os anuncios de 2 em 2 minutos em /g
-- /ie status mostra por que o addon esta (ou nao) convidando

local ADDON = "InviterEscarlate"
local PREFIX = "|cff33ff99Inviter Escarlate|r: "

local defaults = {
    enabled = false,      -- auto-invite ligado?
    mode    = "dungeon",  -- "dungeon" ou "raid"
    heroic  = false,      -- dificuldade
    size    = 10,         -- 10 ou 25 (somente raid)
    keyword = "inv",      -- texto que dispara o invite
    whisper = false,      -- aceitar a palavra-chave por whisper tambem
    message = "",         -- texto do anuncio
    roleFilter = false,   -- filtrar por funcao usando a nota da guild
    mark    = true,       -- marcar o tank (quadrado azul) em dungeon
    quotas  = {           -- vagas por funcao em cada formato
        dungeon = { tank = 1, heal = 1, dps = 3 },
        raid10  = { tank = 2, heal = 3, dps = 5 },
        raid25  = { tank = 3, heal = 6, dps = 16 },
    },
    assigned = {},        -- [nome] = funcao de quem esta no grupo
    raids   = {},         -- [sigla] = true para as raids marcadas no painel
    msgMode = "default",  -- "default" = mensagem padrao com contador; "custom" = texto da caixa
    spec = {},            -- [nome] = main spec informada pelo proprio jogador por whisper
    noteRequests = {},    -- [nome] = funcao que o jogador pediu para colocar na nota
}

-- raids de Wrath que podem ser marcadas no painel (chave, nome na mensagem)
local RAIDS = {
    { "EOE", "EOE" }, { "NAXX", "Naxxramas" }, { "OS", "OS" },
    { "ICC", "ICC" }, { "TOC", "TOC" }, { "RS", "RS" },
}

local DB
local panel
local RefreshConfig

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local function Trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

------------------------------------------------------------------------
-- Logica de grupo
------------------------------------------------------------------------

local function MaxPlayers()
    if DB.mode == "raid" then return DB.size end
    return 5
end

local function GroupSize()
    local raid = GetNumRaidMembers()
    if raid > 0 then return raid end
    return GetNumPartyMembers() + 1
end

local function CanInvite()
    if GetNumRaidMembers() > 0 then
        return IsRaidLeader() or IsRaidOfficer()
    elseif GetNumPartyMembers() > 0 then
        return IsPartyLeader()
    end
    return true
end

local function ApplyDifficulty()
    if DB.mode == "dungeon" then
        SetDungeonDifficulty(DB.heroic and 2 or 1)
    else
        -- 1 = 10 normal, 2 = 25 normal, 3 = 10 heroico, 4 = 25 heroico
        local id
        if DB.size == 10 then
            id = DB.heroic and 3 or 1
        else
            id = DB.heroic and 4 or 2
        end
        SetRaidDifficulty(id)
    end
end

local function ConvertIfNeeded()
    if DB.mode == "raid"
        and GetNumRaidMembers() == 0
        and GetNumPartyMembers() > 0
        and IsPartyLeader() then
        ConvertToRaid()
        ApplyDifficulty() -- garante raid 10 ou 25 (e normal/heroico) conforme o painel
    end
end

-- Grupo cheio e so um bloqueio temporario: a opcao "ligado" nunca e alterada
-- sozinha, entao os convites voltam assim que houver vaga.
-- Retorna true se o grupo esta cheio.
local wasFull = false
local function UpdateFullState()
    local n, max = GroupSize(), MaxPlayers()
    local full = n >= max
    if DB.enabled and full ~= wasFull then
        if full then
            Print(string.format("grupo cheio (%d/%d), convites |cffff0000pausados|r.", n, max))
        else
            Print(string.format("vaga aberta (%d/%d), convites |cff00ff00liberados|r.", n, max))
        end
    end
    wasFull = full
    return full
end

------------------------------------------------------------------------
-- Funcoes (tank / healer / dps) pela nota da guild
------------------------------------------------------------------------

local ROLE_WORDS = {
    tank = "tank", tanque = "tank", tanker = "tank", mt = "tank", ot = "tank",
    heal = "heal", healer = "heal", heals = "heal", hps = "heal", cura = "heal", curador = "heal",
    dps = "dps", dd = "dps", damage = "dps", dano = "dps",
}
local ROLE_NAMES = { tank = "tank", heal = "healer", dps = "DPS" }
local MARKS = { tank = 6 }           -- so o tank e marcado: 6 = quadrado azul
local MIN_LEVEL = 80                 -- nivel minimo para ser convidado
local PENDING_TIMEOUT = 90           -- segundos ate um convite sem resposta liberar a vaga

local pending = {} -- [nome] = { role = funcao, t = GetTime() } de convites ainda nao aceitos

-- lista, em ordem, as funcoes citadas num texto
local function ParseRoles(text)
    local list, seen = {}, {}
    for w in (text or ""):lower():gmatch("%a+") do
        local r = ROLE_WORDS[w]
        if r and not seen[r] then
            seen[r] = true
            list[#list + 1] = r
        end
    end
    return list
end

-- classes que so podem ser DPS: nao precisam de nota
local PURE_DPS = { MAGE = true, WARLOCK = true, HUNTER = true, ROGUE = true }

-- o que cada classe hibrida pode fazer (para validar a resposta do jogador)
local CLASS_ROLES = {
    WARRIOR     = { tank = true, dps = true },
    DEATHKNIGHT = { tank = true, dps = true },
    PALADIN     = { tank = true, heal = true, dps = true },
    DRUID       = { tank = true, heal = true, dps = true },
    SHAMAN      = { heal = true, dps = true },
    PRIEST      = { heal = true, dps = true },
}

-- nota (publica + oficial), classe, indice na lista e nota publica de um membro da guild
local function GuildMember(name)
    if IsInGuild() then
        for i = 1, (GetNumGuildMembers(true) or 0) do
            local n, _, _, level, _, _, note, onote, _, _, classFile = GetGuildRosterInfo(i)
            if n == name then
                return (note or "") .. " " .. (onote or ""), classFile, i, (note or ""), level
            end
        end
    end
    -- fora da guild (ou lista ainda nao carregada): so da para saber a classe de quem esta no grupo
    local _, classFile = UnitClass(name)
    return nil, classFile
end

-- funcoes permitidas para um membro: DPS direto para classes puras; senao o que
-- estiver na nota; sem nada na nota, a main spec que o jogador informou por whisper
local function NoteRoles(name)
    local note, classFile = GuildMember(name)
    if classFile and PURE_DPS[classFile] then return { "dps" } end
    local roles = ParseRoles(note)
    if #roles == 0 and DB.spec[name] then return { DB.spec[name] } end
    return roles
end

local FERAL_TANK_RATIO = 1.6 -- druida feral: vigor >= 1,6 x agilidade conta como tank

-- funcao do proprio jogador, pela spec ativa (ou a fixada com /ie spec)
local function PlayerRole()
    if DB.myRole then return DB.myRole end
    local _, class = UnitClass("player")
    if not class or PURE_DPS[class] then return "dps" end

    -- arvore de talentos com mais pontos na spec ativa
    local best, bestPts = 1, -1
    for tab = 1, 3 do
        local _, _, pts = GetTalentTabInfo(tab)
        pts = pts or 0
        if pts > bestPts then best, bestPts = tab, pts end
    end
    local form = GetShapeshiftForm() or 0
    local _, str = UnitStat("player", 1)
    local _, agi = UnitStat("player", 2)
    local _, sta = UnitStat("player", 3)
    str, agi, sta = str or 0, agi or 0, sta or 0

    if class == "WARRIOR" then
        return best == 3 and "tank" or "dps"
    elseif class == "PALADIN" then
        return best == 1 and "heal" or best == 2 and "tank" or "dps"
    elseif class == "DEATHKNIGHT" then
        -- qualquer arvore pode tankar, entao vale o equipamento: tank tem pericia
        -- em defesa alta (DPS fica em 400) ou vigor como maior atributo
        local base, bonus = UnitDefense("player")
        local defense = (base or 0) + (bonus or 0)
        return (defense >= 500 or sta > str) and "tank" or "dps"
    elseif class == "DRUID" then
        if best == 3 then return "heal" end
        if best == 1 then return "dps" end
        -- feral: urso e gato usam o mesmo tipo de equipamento e vigor costuma ser o
        -- maior atributo dos dois, entao o criterio e a proporcao: equipamento de urso
        -- tem muito mais vigor que agilidade. Forma de urso tambem conta como tank.
        return (form == 1 or sta >= agi * FERAL_TANK_RATIO) and "tank" or "dps"
    elseif class == "SHAMAN" then
        return best == 3 and "heal" or "dps"
    elseif class == "PRIEST" then
        return best == 3 and "dps" or "heal"
    end
    return "dps"
end

local function Quota()
    -- o filtro de funcao so existe em dungeon; raid e controlada manualmente
    return DB.quotas.dungeon
end

local function RoleCount(role)
    -- voce sempre conta, mesmo sozinho, pela sua spec atual
    local me = UnitName("player")
    local c = (PlayerRole() == role) and 1 or 0
    for n, r in pairs(DB.assigned) do
        if n ~= me and r == role then c = c + 1 end
    end
    local now = GetTime()
    for n, p in pairs(pending) do
        if now - p.t > PENDING_TIMEOUT then
            pending[n] = nil
        elseif p.role == role then
            c = c + 1
        end
    end
    return c
end

local function RoleStatusText()
    if DB.mode ~= "dungeon" then
        return "Raid: sem filtro de funcao (controle manual)"
    end
    local q = Quota()
    return string.format("Tank %d/%d    Healer %d/%d    DPS %d/%d",
        RoleCount("tank"), q.tank or 0, RoleCount("heal"), q.heal or 0, RoleCount("dps"), q.dps or 0)
end

local function GroupUnits()
    local t = {}
    local r = GetNumRaidMembers()
    if r > 0 then
        for i = 1, r do t[#t + 1] = "raid" .. i end
    else
        local p = GetNumPartyMembers()
        if p > 0 then
            t[1] = "player"
            for i = 1, p do t[#t + 1] = "party" .. i end
        end
    end
    return t
end

-- atualiza a tabela de funcoes de acordo com quem esta no grupo
local function SyncRoles()
    local inGroup = {}
    for _, u in ipairs(GroupUnits()) do
        local n = UnitName(u)
        if n then
            inGroup[n] = true
            if pending[n] then
                DB.assigned[n] = pending[n].role
                pending[n] = nil
            end
            if not DB.assigned[n] then
                -- entrou sem passar pelo addon: usa a nota se tiver uma funcao so
                local roles = NoteRoles(n)
                if #roles == 1 then DB.assigned[n] = roles[1] end
            end
        end
    end
    local me = UnitName("player")
    if me and inGroup[me] then DB.assigned[me] = PlayerRole() end
    for n in pairs(DB.assigned) do
        if not inGroup[n] then DB.assigned[n] = nil end
    end
end

-- Coloca o quadrado azul no tank, se ele for da guild (cada icone so existe uma vez).
-- Regras para nunca ficar remarcando:
--   * se o icone ja esta em qualquer pessoa do grupo (mesmo colocado a mao, mesmo
--     em alguem sem funcao conhecida, como quem e de fora da guild), nao mexe;
--   * cada pessoa so e marcada uma vez pelo addon enquanto estiver no grupo.
local markedOnce = {} -- [icone] = nome de quem o addon ja marcou

local function UpdateMarks()
    if not DB.mark or DB.mode ~= "dungeon" then return end
    if GetNumRaidMembers() > 0 and not (IsRaidLeader() or IsRaidOfficer()) then return end

    local units = GroupUnits()
    local inGroup = {}
    for _, u in ipairs(units) do
        local n = UnitName(u)
        if n then inGroup[n] = true end
    end
    for icon, n in pairs(markedOnce) do
        if not inGroup[n] then markedOnce[icon] = nil end
    end

    for role, icon in pairs(MARKS) do
        local taken, candidate = false, nil
        for _, u in ipairs(units) do
            if GetRaidTargetIndex(u) == icon then
                taken = true
                break
            end
            local n = UnitName(u)
            -- so marca quem e da guild (indice na lista da guild)
            if not candidate and n and DB.assigned[n] == role and select(3, GuildMember(n)) then
                candidate = u
            end
        end
        if not taken and candidate then
            local n = UnitName(candidate)
            if markedOnce[icon] ~= n then
                markedOnce[icon] = n
                SetRaidTarget(candidate, icon)
            end
        end
    end
end

local function Whisper(name, text)
    SendChatMessage("[Inviter Escarlate] " .. text, "WHISPER", nil, name)
end

-- conversas por whisper em andamento: [nome] = { stage = "spec" | "note", role = funcao, t = GetTime() }
local asking = {}
local ASK_TIMEOUT = 300 -- segundos que a pergunta fica valendo

local function AskSpec(name)
    asking[name] = { stage = "spec", t = GetTime() }
    Whisper(name, "Qual a sua main spec? Responda neste whisper apenas com DPS, HEAL ou TANK.")
    Print(name .. " nao tem funcao na nota da guild; perguntei a main spec por whisper.")
end

-- decide a funcao de quem pediu invite, sem depender do texto da mensagem:
-- classe so-DPS entra como DPS; as demais usam a nota da guild e, se a nota tiver
-- mais de uma funcao, entra na primeira (na ordem da nota) que ainda tiver vaga.
-- Retorna nil (e avisa por whisper) se nao puder entrar.
local function ResolveRole(name)
    local allowed = NoteRoles(name)
    if #allowed == 0 then
        AskSpec(name)
        return nil
    end

    local q = Quota()
    local names = {}
    for _, r in ipairs(allowed) do
        if RoleCount(r) < (q[r] or 0) then return r end
        names[#names + 1] = ROLE_NAMES[r]
    end
    Whisper(name, "sem vaga de " .. table.concat(names, "/") .. " no momento.")
    Print(name .. " nao foi convidado: sem vaga de " .. table.concat(names, "/") .. ".")
    return nil
end

-- texto das vagas que faltam, da maior para a menor: "3 DPS e 1 tank"
local function MissingText()
    local q = Quota()
    local list = {}
    for i, r in ipairs({ "tank", "heal", "dps" }) do
        local m = (q[r] or 0) - RoleCount(r)
        if m > 0 then list[#list + 1] = { n = m, i = i, label = ROLE_NAMES[r] } end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.i < b.i
    end)
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = e.n .. " " .. e.label end
    if #parts == 1 then return parts[1] end
    return table.concat(parts, ", ", 1, #parts - 1) .. " e " .. parts[#parts]
end

-- palavra que a mensagem padrao manda digitar: a palavra-chave do painel, ou @ se estiver vazia
local function InviteWord()
    local kw = Trim(DB.keyword or "")
    return kw ~= "" and kw or "@"
end

-- mensagem padrao, com o contador do momento; nil se nao falta ninguem
local function DefaultMessage()
    local tail = ". Mande " .. InviteWord() .. " no guild chat para ser convidado para o grupo."
    if DB.mode == "dungeon" then
        local missing = MissingText()
        if not missing then return nil end
        return "Invitando " .. (DB.heroic and "Dungeon HC" or "Dungeon normal") .. ": falta " .. missing .. tail
    end
    -- raid: sem contador de vagas na mensagem (so deixa de anunciar com a raid cheia)
    if GroupSize() >= MaxPlayers() then return nil end
    local names = {}
    for _, r in ipairs(RAIDS) do
        if DB.raids[r[1]] then names[#names + 1] = r[2] end
    end
    local what = #names > 0 and table.concat(names, "/") or "Raid"
    return string.format("Invitando %s %d%s", what, DB.size, DB.heroic and " heroico" or "") .. tail
end

-- texto a anunciar conforme a escolha do painel; nil + motivo se nao ha o que enviar
local function AnnouncementText()
    if DB.msgMode == "custom" then
        local t = Trim((DB.message or ""):gsub("\n", " "))
        if t == "" then return nil, "o texto customizado esta vazio." end
        return t
    end
    local t = DefaultMessage()
    if not t then return nil, "grupo completo, nao ha vagas para anunciar." end
    return t
end

-- Anuncios periodicos em /g. So rodam depois que voce clica em "Iniciar anuncios",
-- param sozinhos quando o grupo completa e nunca sobrevivem a login ou /reload.
local ANNOUNCE_INTERVAL = 120 -- segundos entre um anuncio e outro
local announcing = false
local nextAnnounce = 0

local function StopAnnouncing(reason)
    if not announcing then return end
    announcing = false
    Print("anuncios |cffff0000parados|r" .. (reason and (": " .. reason) or "."))
    RefreshConfig()
end

local function StartAnnouncing()
    if not IsInGuild() then
        Print("voce nao esta em uma guild.")
        return
    end
    local text, err = AnnouncementText()
    if not text then
        Print(err)
        return
    end
    announcing = true
    nextAnnounce = 0 -- o primeiro sai na hora
    Print("anuncios |cff00ff00iniciados|r: um a cada 2 minutos em /g.")
    RefreshConfig()
end

local announceTimer = CreateFrame("Frame")
announceTimer:SetScript("OnUpdate", function()
    if not announcing or not DB then return end
    local now = GetTime()
    if now < nextAnnounce then return end
    local text, err = AnnouncementText()
    if not text then
        StopAnnouncing(err)
        return
    end
    nextAnnounce = now + ANNOUNCE_INTERVAL
    SendChatMessage(text, "GUILD")
end)

-- Localizador de Masmorras: ao entrar na fila, desliga o auto-invite e os anuncios.
-- So age na entrada da fila; se voce religar a mao, fica ligado.
local LFG_ACTIVE = { queued = true, rolecheck = true, proposal = true, lfgparty = true }
local wasInLFG = false

local function CheckLFG()
    if not GetLFGMode then return end
    local inLFG = LFG_ACTIVE[GetLFGMode() or ""] or false
    if inLFG and not wasInLFG then
        if DB.enabled then
            DB.enabled = false
            Print("fila do Localizador de Masmorras: auto-invite |cffff0000desligado|r.")
        end
        StopAnnouncing("voce entrou na fila do Localizador de Masmorras.")
        RefreshConfig()
    end
    wasInLFG = inLFG
end

local function TryInvite(name, msg)
    if not DB.enabled then return end
    if not name or name == "" or name == UnitName("player") then return end
    if UnitInParty(name) or UnitInRaid(name) then return end

    if not CanInvite() then
        Print("nao foi possivel convidar " .. name .. " (voce nao e lider/assistente).")
        return
    end

    if UpdateFullState() then
        Print(name .. " pediu invite, mas o grupo esta cheio.")
        return
    end

    local _, _, _, _, level = GuildMember(name)
    if level and level < MIN_LEVEL then
        Print(string.format("%s nao foi convidado: nivel %d (minimo %d).", name, level, MIN_LEVEL))
        Whisper(name, string.format("Os convites sao so para nivel %d.", MIN_LEVEL))
        return
    end

    local role
    if DB.roleFilter and DB.mode == "dungeon" then
        role = ResolveRole(name)
        if not role then return end
    end

    ConvertIfNeeded()
    InviteUnit(name)
    if role then
        pending[name] = { role = role, t = GetTime() }
    end
    RefreshConfig()
end

local function MatchesKeyword(msg)
    -- qualquer frase que contenha "@" ja dispara o invite
    if msg:find("@", 1, true) then return true end
    local kw = Trim(DB.keyword or ""):lower()
    if kw == "" then return false end
    return Trim(msg):lower() == kw
end

local YES = { sim = true, s = true, yes = true, y = true, quero = true }
local NO  = { nao = true, ["n\195\163o"] = true, ["n\195\131o"] = true, n = true, no = true }

-- trata a resposta de quem recebeu uma pergunta do addon.
-- Retorna true se o whisper fazia parte dessa conversa.
local function HandleAnswer(name, msg)
    local a = asking[name]
    if not a then return false end
    if GetTime() - a.t > ASK_TIMEOUT then
        asking[name] = nil
        return false
    end
    local text = Trim((Trim(msg):lower():gsub("[%.!%?]+$", "")))

    if a.stage == "spec" then
        -- vale qualquer resposta que cite uma unica funcao, mesmo com outras palavras
        -- junto ("dps shaman elemental"); sem funcao nenhuma, o whisper e ignorado
        local roles = ParseRoles(text)
        if #roles == 0 then return false end
        if #roles > 1 then
            Whisper(name, "Preciso de uma funcao so, a principal. Responda apenas com DPS, HEAL ou TANK.")
            return true
        end
        local role = roles[1]

        local _, classFile = GuildMember(name)
        local can = classFile and CLASS_ROLES[classFile]
        if can and not can[role] then
            Whisper(name, "Sua classe nao pode ser " .. ROLE_NAMES[role] .. ". Responda apenas com DPS, HEAL ou TANK.")
            return true
        end

        DB.spec[name] = role
        asking[name] = { stage = "note", role = role, t = GetTime() }
        Print(name .. " informou main spec: " .. ROLE_NAMES[role] .. ".")
        Whisper(name, "Anotado: " .. ROLE_NAMES[role] .. ". Quer que o responsavel pelo invite coloque isso na sua nota da guild? Responda SIM ou NAO.")
        TryInvite(name)
        return true
    end

    -- stage "note": vale a primeira palavra ("sim por favor", "nao precisa")
    text = text:match("^[^%s,%.!]+") or text
    if YES[text] then
        asking[name] = nil
        -- escreve a funcao na nota publica, mas so se ela estiver vazia
        local _, _, index, publicNote = GuildMember(name)
        if index and Trim(publicNote) == "" and CanEditPublicNote() then
            local tag = string.upper(a.role)
            GuildRosterSetPublicNote(index, tag)
            GuildRoster()
            Print(name .. ": nota publica da guild preenchida com " .. tag .. ".")
            Whisper(name, "Pronto, sua nota da guild agora e " .. tag .. ".")
            return true
        end
        -- nota ja preenchida ou sem permissao: fica como pedido para alterar a mao
        DB.noteRequests[name] = a.role
        Print("|cffffff00" .. name .. " pediu para colocar " .. ROLE_NAMES[a.role] .. " na nota da guild.|r (lista: /ie notas)")
        PlaySound("TellMessage")
        Whisper(name, "Ok, pedido registrado.")
        return true
    elseif NO[text] then
        asking[name] = nil
        Whisper(name, "Ok, sua nota fica como esta.")
        return true
    end
    return false
end

------------------------------------------------------------------------
-- Envio do anuncio
------------------------------------------------------------------------

local function SendAnnouncement(chatType, channel)
    local text, err = AnnouncementText()
    if not text then
        Print(err)
        return
    end
    if chatType == "GUILD" and not IsInGuild() then
        Print("voce nao esta em uma guild.")
        return
    end
    if chatType == "CHANNEL" and GetChannelName(channel) == 0 then
        Print("voce nao esta no canal " .. channel .. ".")
        return
    end
    SendChatMessage(text, chatType, nil, channel)
end

------------------------------------------------------------------------
-- Helpers de UI
------------------------------------------------------------------------

local function Label(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function Radio(parent, name, text, x, y, onClick)
    local b = CreateFrame("CheckButton", name, parent, "UIRadioButtonTemplate")
    b:SetPoint("TOPLEFT", x, y)
    _G[name .. "Text"]:SetText(text)
    b:SetScript("OnClick", function()
        onClick()
        UpdateFullState()
        RefreshConfig()
    end)
    return b
end

local function Check(parent, name, text, x, y, onClick)
    local b = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    b:SetPoint("TOPLEFT", x, y)
    _G[name .. "Text"]:SetText(text)
    b:SetScript("OnClick", function(self)
        onClick(self:GetChecked() and true or false)
        RefreshConfig()
    end)
    return b
end

local function Button(parent, text, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(w)
    b:SetHeight(24)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- caixa de marcar habilitada (texto dourado) ou cinza e sem clique
local function SetCheckEnabled(b, enabled)
    local text = _G[b:GetName() .. "Text"]
    if enabled then
        b:Enable()
        text:SetTextColor(1, 0.82, 0)
    else
        b:Disable()
        text:SetTextColor(0.5, 0.5, 0.5)
    end
end

local function SetRadioEnabled(b, enabled)
    local text = _G[b:GetName() .. "Text"]
    if enabled then
        b:Enable()
        text:SetTextColor(1, 1, 1)
    else
        b:Disable()
        text:SetTextColor(0.5, 0.5, 0.5)
    end
end

------------------------------------------------------------------------
-- Painel em Interface > AddOns
------------------------------------------------------------------------

local ui = {}
local panels = {}      -- as tres paginas em Interface > AddOns
local PAGE_WIDTH = 360 -- cabe na janela de opcoes padrao do jogo (sem addons de interface)

local function AnyPanelShown()
    for _, p in ipairs(panels) do
        if p:IsShown() then return true end
    end
    return false
end
local refreshing = false

RefreshConfig = function()
    if not panel then return end
    ui.enabled:SetChecked(DB.enabled)
    ui.whisper:SetChecked(DB.whisper)
    ui.dungeon:SetChecked(DB.mode == "dungeon")
    ui.raid:SetChecked(DB.mode == "raid")
    ui.normal:SetChecked(not DB.heroic)
    ui.heroic:SetChecked(DB.heroic)
    ui.size10:SetChecked(DB.size == 10)
    ui.size25:SetChecked(DB.size == 25)
    SetRadioEnabled(ui.size10, DB.mode == "raid")
    SetRadioEnabled(ui.size25, DB.mode == "raid")
    if not ui.keyword:HasFocus() then
        ui.keyword:SetText(DB.keyword or "")
    end
    if not ui.message:HasFocus() then
        ui.message:SetText(DB.message or "")
    end
    local n, max = GroupSize(), MaxPlayers()
    ui.status:SetText(string.format("Vagas: %d / %d%s", n, max, n >= max and "  (cheio, convites pausados)" or ""))
    ui.roleFilter:SetChecked(DB.roleFilter)
    ui.mark:SetChecked(DB.mark)
    -- filtro de funcao e marcacao do tank so existem em dungeon
    SetCheckEnabled(ui.roleFilter, DB.mode == "dungeon")
    SetCheckEnabled(ui.mark, DB.mode == "dungeon")
    for key, box in pairs(ui.raids) do
        box:SetChecked(DB.raids[key])
        SetCheckEnabled(box, DB.mode == "raid")
    end
    ui.announceBtn:SetText(announcing and "Parar anuncios (a cada 2 min em /g)" or "Iniciar anuncios (a cada 2 min em /g)")
    ui.msgDefault:SetChecked(DB.msgMode ~= "custom")
    ui.msgCustom:SetChecked(DB.msgMode == "custom")
    ui.preview:SetText("Padrao agora: " .. (DefaultMessage() or "(grupo completo, nada a anunciar)"))
    refreshing = true
    for key, box in pairs(ui.quota) do
        if not box:HasFocus() then box:SetText(Quota()[key] or 0) end
    end
    refreshing = false
    ui.roleStatus:SetText(RoleStatusText())
    ui.myRole:SetText("Sua funcao: " .. ROLE_NAMES[PlayerRole()] .. (DB.myRole and " (fixada)" or " (pela spec atual)"))
end

-- Pagina principal: convites
local function BuildInvitePage(f)
    ui.enabled = Check(f, "InviterEscarlateEnabled", "Auto-invite ligado", 0, 0,
        function(v)
            DB.enabled = v
            if v then
                ApplyDifficulty()
            end
        end)

    Label(f, "Tipo", 4, -42)
    ui.dungeon = Radio(f, "InviterEscarlateModeDungeon", "Dungeon (5)", 10, -60,
        function() DB.mode = "dungeon"; ApplyDifficulty() end)
    ui.raid = Radio(f, "InviterEscarlateModeRaid", "Raid", 140, -60,
        function() DB.mode = "raid"; ApplyDifficulty(); ConvertIfNeeded() end)

    Label(f, "Dificuldade", 4, -90)
    ui.normal = Radio(f, "InviterEscarlateDiffNormal", "Normal", 10, -108,
        function() DB.heroic = false; ApplyDifficulty() end)
    ui.heroic = Radio(f, "InviterEscarlateDiffHeroic", "Heroico", 140, -108,
        function() DB.heroic = true; ApplyDifficulty() end)

    Label(f, "Tamanho da raid", 4, -138)
    ui.size10 = Radio(f, "InviterEscarlateSize10", "10 jogadores", 10, -156,
        function() DB.size = 10; ApplyDifficulty() end)
    ui.size25 = Radio(f, "InviterEscarlateSize25", "25 jogadores", 140, -156,
        function() DB.size = 25; ApplyDifficulty() end)

    Label(f, "Palavra-chave do invite", 4, -188)
    local eb = CreateFrame("EditBox", "InviterEscarlateKeyword", f, "InputBoxTemplate")
    eb:SetWidth(230)
    eb:SetHeight(20)
    eb:SetPoint("TOPLEFT", 12, -206)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(60)
    eb:SetScript("OnTextChanged", function(self)
        DB.keyword = self:GetText()
        if ui.preview then
            ui.preview:SetText("Padrao agora: " .. (DefaultMessage() or "(grupo completo, nada a anunciar)"))
        end
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ui.keyword = eb

    ui.whisper = Check(f, "InviterEscarlateWhisper", "Aceitar tambem por whisper", 0, -230,
        function(v) DB.whisper = v end)

    ui.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.status:SetPoint("TOPLEFT", 4, -272)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 4, -296)
    hint:SetWidth(PAGE_WIDTH - 8)
    hint:SetJustifyH("LEFT")
    hint:SetText("Mais opcoes nas paginas \"Funcoes e raids\" e \"Anuncios\", no + ao lado de Inviter Escarlate na lista.")
end

-- Pagina "Funcoes e raids": filtro de funcao (dungeon) e raids da mensagem (raid)
local function BuildRolesPage(f)
    Label(f, "Dungeon", 4, -2)
    ui.roleFilter = Check(f, "InviterEscarlateRoleFilter", "Filtrar por funcao em dungeon (nota da guild)", 0, -18,
        function(v)
            DB.roleFilter = v
            if v and IsInGuild() then GuildRoster() end
        end)

    local prev = Label(f, "Vagas:", 4, -60) -- sempre as vagas de dungeon
    ui.quota = {}
    for _, r in ipairs({ { "tank", "Tank" }, { "heal", "Healer" }, { "dps", "DPS" } }) do
        local key, text = r[1], r[2]
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("LEFT", prev, "RIGHT", 12, 0)
        l:SetText(text)

        local q = CreateFrame("EditBox", "InviterEscarlateQuota" .. key, f, "InputBoxTemplate")
        q:SetWidth(24)
        q:SetHeight(20)
        q:SetPoint("LEFT", l, "RIGHT", 8, 0)
        q:SetAutoFocus(false)
        q:SetNumeric(true)
        q:SetMaxLetters(2)
        q:SetScript("OnTextChanged", function(self)
            if refreshing then return end
            Quota()[key] = tonumber(self:GetText()) or 0
            ui.roleStatus:SetText(RoleStatusText())
        end)
        q:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        q:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        ui.quota[key] = q
        prev = q
    end

    ui.mark = Check(f, "InviterEscarlateMark", "Marcar o tank em dungeon (quadrado azul)", 0, -80,
        function(v)
            DB.mark = v
            if v then UpdateMarks() end
        end)

    ui.roleStatus = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.roleStatus:SetPoint("TOPLEFT", 4, -120)

    ui.myRole = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.myRole:SetPoint("TOPLEFT", 4, -142)

    -- raids que entram no nome da mensagem padrao (so no modo raid)
    ui.raidsLabel = Label(f, "Raid: nome na mensagem padrao", 4, -182)
    ui.raids = {}
    for i, r in ipairs(RAIDS) do
        local key = r[1]
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        ui.raids[key] = Check(f, "InviterEscarlateRaid" .. key, r[2], col * 110, -198 - row * 28,
            function(v) DB.raids[key] = v or nil end)
    end
end

-- Pagina "Anuncios": mensagem padrao ou customizada e envio
local function BuildAnnouncePage(f)
    Label(f, "Mensagem enviada", 4, -2)
    ui.msgDefault = Radio(f, "InviterEscarlateMsgDefault", "Mensagem padrão", 10, -20,
        function() DB.msgMode = "default" end)
    ui.msgCustom = Radio(f, "InviterEscarlateMsgCustom", "Customizada", 170, -20,
        function() DB.msgMode = "custom" end)

    Label(f, "Texto customizado", 4, -48)

    local bg = CreateFrame("Frame", nil, f)
    bg:SetPoint("TOPLEFT", 0, -66)
    bg:SetWidth(PAGE_WIDTH)
    bg:SetHeight(110)
    bg:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0, 0, 0, 0.6)
    bg:SetBackdropBorderColor(0.6, 0.6, 0.6)

    local sf = CreateFrame("ScrollFrame", "InviterEscarlateMessageScroll", bg, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 8, -8)
    sf:SetPoint("BOTTOMRIGHT", -28, 8)

    local eb = CreateFrame("EditBox", "InviterEscarlateMessageEdit", sf)
    eb:SetMultiLine(true)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(PAGE_WIDTH - 40)
    eb:SetHeight(90)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(255) -- limite de uma mensagem de chat
    sf:SetScrollChild(eb)
    ui.message = eb

    local counter = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    counter:SetPoint("TOPRIGHT", bg, "BOTTOMRIGHT", -4, -4)

    eb:SetScript("OnTextChanged", function(self)
        DB.message = self:GetText()
        counter:SetText(self:GetNumLetters() .. " / 255")
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    sf:EnableMouse(true)
    sf:SetScript("OnMouseDown", function() eb:SetFocus() end)

    local half = math.floor(PAGE_WIDTH / 2) - 5
    local g = Button(f, "Enviar /g", half, function()
        eb:ClearFocus()
        SendAnnouncement("GUILD")
    end)
    g:SetPoint("TOPLEFT", bg, "BOTTOMLEFT", 0, -22)

    local c5 = Button(f, "Enviar /5", half, function()
        eb:ClearFocus()
        SendAnnouncement("CHANNEL", 5)
    end)
    c5:SetPoint("TOPRIGHT", bg, "BOTTOMRIGHT", 0, -22)

    ui.announceBtn = Button(f, "Iniciar anuncios", PAGE_WIDTH, function()
        if announcing then StopAnnouncing() else StartAnnouncing() end
    end)
    ui.announceBtn:SetPoint("TOPLEFT", g, "BOTTOMLEFT", 0, -10)

    ui.preview = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.preview:SetPoint("TOPLEFT", ui.announceBtn, "BOTTOMLEFT", 4, -10)
    ui.preview:SetWidth(PAGE_WIDTH - 8)
    ui.preview:SetJustifyH("LEFT")
end

-- cria uma pagina em Interface > AddOns; parentName = nil para a principal
local function MakePage(frameName, name, parentName, subtitle, build)
    local p = CreateFrame("Frame", frameName, InterfaceOptionsFramePanelContainer)
    p.name = name
    p.parent = parentName
    p:Hide()

    local title = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(parentName and (parentName .. " - " .. name) or name)

    local sub = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    sub:SetWidth(PAGE_WIDTH)
    sub:SetHeight(24)
    sub:SetJustifyH("LEFT")
    sub:SetJustifyV("TOP")
    sub:SetText(subtitle)

    local content = CreateFrame("Frame", nil, p)
    content:SetPoint("TOPLEFT", 16, -64)
    content:SetWidth(PAGE_WIDTH)
    content:SetHeight(340)
    build(content)

    p.refresh = RefreshConfig
    p:SetScript("OnShow", RefreshConfig)
    InterfaceOptions_AddCategory(p)
    panels[#panels + 1] = p
    return p
end

local function BuildPanel()
    local main = MakePage("InviterEscarlateOptionsPanel", "Inviter Escarlate", nil,
        "Convida quem mandar @ ou a palavra-chave no chat da guild.", BuildInvitePage)
    MakePage("InviterEscarlateRolesPanel", "Funcoes e raids", "Inviter Escarlate",
        "Vagas por funcao em dungeon e raids citadas na mensagem.", BuildRolesPage)
    MakePage("InviterEscarlateAnnouncePanel", "Anuncios", "Inviter Escarlate",
        "Mensagem de chamada e envio para /g e /5.", BuildAnnouncePage)
    panel = main
end

------------------------------------------------------------------------
-- Eventos
------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("CHAT_MSG_GUILD")
ev:RegisterEvent("CHAT_MSG_WHISPER")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_TALENT_UPDATE")
ev:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
ev:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("LFG_UPDATE")
ev:RegisterEvent("LFG_ROLE_CHECK_SHOW")
ev:RegisterEvent("LFG_PROPOSAL_SHOW")
ev:RegisterEvent("LFG_QUEUE_STATUS_UPDATE")

ev:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        -- aproveita as configuracoes do nome antigo (Fantu Inviter), se o arquivo foi renomeado
        InviterEscarlateDB = InviterEscarlateDB or FantuInviterDB or {}
        FantuInviterDB = nil
        DB = InviterEscarlateDB
        for k, v in pairs(defaults) do
            if DB[k] == nil then DB[k] = v end
        end
        if DB.pausedFull then DB.enabled = true end
        DB.pausedFull = nil
        BuildPanel()
        Print("carregado. Digite /ie ou abra Interface > AddOns > Inviter Escarlate.")
        return
    end

    if not DB then return end

    if event == "CHAT_MSG_GUILD" then
        if MatchesKeyword(arg1) then TryInvite(arg2, arg1) end

    elseif event:sub(1, 4) == "LFG_" then
        CheckLFG()

    elseif event ~= "CHAT_MSG_WHISPER" and event ~= "PARTY_MEMBERS_CHANGED" and event ~= "RAID_ROSTER_UPDATE" then
        -- entrada no mundo, lista da guild, troca de talentos/spec/forma
        if event == "PLAYER_ENTERING_WORLD" and IsInGuild() then GuildRoster() end
        SyncRoles()
        UpdateMarks()
        if AnyPanelShown() then RefreshConfig() end

    elseif event == "CHAT_MSG_WHISPER" then
        if HandleAnswer(arg2, arg1) then return end
        if DB.whisper and MatchesKeyword(arg1) then TryInvite(arg2, arg1) end

    else -- PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE
        if DB.enabled then ConvertIfNeeded() end
        UpdateFullState()
        SyncRoles()
        UpdateMarks()
        if AnyPanelShown() then RefreshConfig() end
    end
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

SLASH_INVITERESCARLATE1 = "/ie"
SLASH_INVITERESCARLATE2 = "/inviterescarlate"
SLASH_INVITERESCARLATE3 = "/fi" -- comando antigo, mantido por habito
SlashCmdList["INVITERESCARLATE"] = function(msg)
    msg = Trim(msg or ""):lower()
    if msg == "on" then
        DB.enabled = true
        ApplyDifficulty()
        RefreshConfig()
        Print("auto-invite |cff00ff00ligado|r.")
    elseif msg == "off" then
        DB.enabled = false
        RefreshConfig()
        Print("auto-invite |cffff0000desligado|r.")
    elseif msg:match("^spec") then
        local arg = Trim(msg:sub(5))
        if arg == "auto" then
            DB.myRole = nil
        elseif ROLE_WORDS[arg] then
            DB.myRole = ROLE_WORDS[arg]
        elseif arg ~= "" then
            Print("use /ie spec tank, /ie spec heal, /ie spec dps ou /ie spec auto.")
            return
        end
        SyncRoles()
        UpdateMarks()
        RefreshConfig()
        Print("sua funcao: " .. ROLE_NAMES[PlayerRole()] .. (DB.myRole and " (fixada)" or " (pela spec atual)") .. ".")
        local _, class = UnitClass("player")
        if class == "DEATHKNIGHT" or class == "DRUID" then
            local _, str = UnitStat("player", 1)
            local _, agi = UnitStat("player", 2)
            local _, sta = UnitStat("player", 3)
            local base, bonus = UnitDefense("player")
            local apBase, apPos, apNeg = UnitAttackPower("player")
            Print(string.format("forca %d, agilidade %d, vigor %d, defesa %d, vida %d, poder de ataque %d, forma %d.",
                str or 0, agi or 0, sta or 0, (base or 0) + (bonus or 0), UnitHealthMax("player") or 0,
                (apBase or 0) + (apPos or 0) + (apNeg or 0), GetShapeshiftForm() or 0))
        end
    elseif msg == "anuncios" or msg == "anuncio" then
        if announcing then StopAnnouncing() else StartAnnouncing() end
    elseif msg == "notas limpar" then
        for n in pairs(DB.noteRequests) do DB.noteRequests[n] = nil end
        Print("lista de pedidos de nota apagada.")
    elseif msg == "notas" then
        local any = false
        for n, r in pairs(DB.noteRequests) do
            any = true
            Print(n .. " -> " .. ROLE_NAMES[r])
        end
        if not any then Print("nenhum pedido de alteracao de nota.") end
    elseif msg == "status" then
        local onoff = function(v) return v and "|cff00ff00sim|r" or "|cffff0000nao|r" end
        Print("auto-invite ligado: " .. onoff(DB.enabled))
        Print(string.format("formato: %s, grupo %d/%d",
            DB.mode == "raid" and ("raid " .. DB.size) or "dungeon", GroupSize(), MaxPlayers()))
        Print("voce pode convidar (lider/assistente): " .. onoff(CanInvite()))
        Print("sua funcao: " .. ROLE_NAMES[PlayerRole()] .. (DB.myRole and " (fixada)" or " (pela spec atual)"))
        Print("filtro de funcao ativo agora: " .. onoff(DB.roleFilter and DB.mode == "dungeon"))
        Print("palavra-chave: \"" .. (DB.keyword or "") .. "\" (alem de qualquer frase com @)")
    else
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end
