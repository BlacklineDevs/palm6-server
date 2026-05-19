-- ============================================================================
-- config_overrides/qbx_core/config.lua
--
-- Server-owner-controlled overrides for qbx_core. The recipe-provided
-- qbx_core is NOT vendored — this resource only ships the values we want
-- applied at runtime via convars + a small server boot script.
--
-- Source of truth for character creation, identifiers, and starting funds.
-- ============================================================================

Override = {}

-- ---------------------------------------------------------------------------
-- Multichar / character creation
-- ---------------------------------------------------------------------------

-- Maximum characters per player (small-server default for 48 slots).
Override.MaxCharacters = 2

-- Identifier types required at join. qbx_core key: PVP / identifier checks.
-- Discord is required so allowlist + role gating can hang off the same id.
Override.RequiredIdentifiers = {
    'license',
    'discord',
}

-- Allowed nationalities shown in the character-creation UI. Empty table
-- means "do not restrict".
Override.AllowedNationalities = {
    'American', 'British', 'Canadian', 'Mexican', 'Irish', 'Italian',
    'German', 'French', 'Japanese', 'Korean', 'Other',
}

-- DOB bounds (years). Used to validate the character-creation form.
Override.DOB = {
    minYear = 1960,
    maxYear = 2006,
}

-- Name regex applied to first + last name. Letters, spaces, hyphens,
-- apostrophes; 2-24 chars per part.
Override.NameRegex = "^[A-Za-z][A-Za-z%-' ]+$"
Override.NameMinLen = 2
Override.NameMaxLen = 24

-- ---------------------------------------------------------------------------
-- Starting funds for a brand-new character
-- ---------------------------------------------------------------------------
-- These are the values server_base/phase 2 will rely on. Keep small enough
-- that paychecks still matter, large enough that the first hour is playable.
Override.StartingMoney = {
    cash = 500,
    bank = 5000,
    crypto = 0,
}
