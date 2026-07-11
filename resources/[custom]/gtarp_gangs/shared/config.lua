-- ============================================================================
-- gtarp_gangs/shared/config.lua — engine-agnostic tunables (Tier 1, carries
-- to GTA VI). No world coords at all — this whole resource is management +
-- ledger + rep, so there is nothing Tier-3 to retune when the VI map lands.
--
-- DESIGN INTENT — the player-run gang layer Qbox does NOT ship.
-- qbx_core already provides the STATIC gang DATA model: predefined gangs +
-- grades in shared config, PlayerData.gang, and /setgang — the exact analog
-- of its jobs. What it has NO concept of is a gang players can CREATE and
-- RUN themselves: membership management, a shared vault, and reputation.
-- That is what qb-gangs / ps-gangs add to QBCore, and it is precisely this
-- resource's scope. We do NOT re-implement qbx's static registry; we build
-- the missing player-created / membership / vault / rep layer on our own
-- tables (gtarp_gangs, gtarp_gang_members, gtarp_gang_vault_log) and expose
-- it through server-only exports (GetGang / IsSameGang / AddRep / GetSummary)
-- so turf/protection/drugs can reward gang activity later.
-- ============================================================================
Config = {}

Config.Debug = false

-- The command that opens the gang menu.
Config.Command = 'gang'

-- ---------------------------------------------------------------------------
-- Creation
-- ---------------------------------------------------------------------------
-- Cost to found a gang, charged from the founder's BANK (server re-validates
-- affordability before creating). Set 0 to make creation free.
Config.CreationCost = 50000

-- Cost to rename a gang, charged from the leader's BANK (refunded on failure).
-- Set 0 to make renaming free. Leader-only; server re-validates affordability
-- before applying the new name/tag.
Config.RenameCost = 25000

-- Name: 3-24 chars after sanitising to letters/digits/spaces (collapsed).
Config.NameMinLen = 3
Config.NameMaxLen = 24
-- Tag: 2-5 chars, letters/digits only, upper-cased.
Config.TagMinLen = 2
Config.TagMaxLen = 5

-- Case-insensitive substring blocklist for name AND tag. Kept small and
-- obvious — this is a first-line profanity/impersonation filter, not a
-- exhaustive moderation system (staff can still disband via DB).
Config.Blocklist = {
    'nigger', 'faggot', 'retard', 'rape', 'nazi', 'hitler', 'kkk',
    'cunt', 'admin', 'staff', 'police', 'server',
}

-- ---------------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------------
Config.MaxMembers = 12

-- Rank ladder. Higher number = more authority. These are our OWN ranks
-- (distinct from qbx grade integers). Do not renumber without a migration —
-- gtarp_gang_members.rank stores these values.
Config.Rank = { Member = 1, Officer = 2, Leader = 3 }
Config.RankName = { [1] = 'Member', [2] = 'Officer', [3] = 'Leader' }

-- Minimum rank required for each gated action (server-enforced).
Config.MinRank = {
    Invite   = Config.Rank.Officer,  -- officer+ can invite
    Kick     = Config.Rank.Officer,  -- officer+ can kick STRICTLY-lower ranks
    Withdraw = Config.Rank.Officer,  -- officer+ can withdraw from the vault
    Promote  = Config.Rank.Leader,   -- leader only
    Demote   = Config.Rank.Leader,   -- leader only
    Disband  = Config.Rank.Leader,   -- leader only
    -- Deposit + Leave are open to any member (no entry here).
}

-- Invites: the inviter's nearest gangless online player within this radius
-- (metres) gets the prompt. Server picks the target from real ped positions,
-- so the client never supplies who to invite. Pending invites expire.
Config.InviteRadius = 6.0
Config.InviteExpirySec = 60

-- ---------------------------------------------------------------------------
-- Vault (CASH vault — auditable, chosen over an ox_inventory stash per the
-- brief). Deposits pull the founder-currency CASH the player is holding;
-- withdrawals hand cash back. Every move is atomic + logged.
-- ---------------------------------------------------------------------------
Config.VaultMinAmount = 1
Config.VaultMaxPerAction = 1000000   -- sanity clamp on a single deposit/withdraw

-- ---------------------------------------------------------------------------
-- qbx_core gang-identity mirror (integration seam, OFF by default).
-- Our tables are the authoritative source of truth for PLAYER-RUN gangs.
-- qbx_core's SetGang validates against its STATIC gang registry, so mirroring
-- a player-created gang name into PlayerData.gang only "sticks" if an operator
-- has also registered that gang in qbx_core's shared gang config. Left OFF so
-- we never fight the framework or corrupt PlayerData; flip on only once the
-- qbx gang registry is wired to accept these names. The mirror is best-effort
-- and pcall-guarded either way (see bridge Bridge.MirrorQbxGang).
-- ---------------------------------------------------------------------------
Config.MirrorToQbxGang = false
