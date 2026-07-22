-- ===========================================================================
-- palm6_dbmigrate — ONE-SHOT idempotent migration applier
-- ---------------------------------------------------------------------------
-- The prod DB (db-dtx-06) is not reachable from outside the panel network and
-- CI never touches the DB, so migrations 0040 + 0042-0047 are applied here
-- using the game server's own oxmysql connection on boot. Every statement is
-- IF NOT EXISTS, so re-running is a harmless no-op. Each runs independently
-- (pcall-guarded) so one failure never blocks the rest. REMOVE this resource
-- after the console shows all statements OK and the tables are confirmed.
-- ===========================================================================

local STATEMENTS = {
    { name = '0040 palm6_drugs_processes', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_drugs_processes` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    owner_cid VARCHAR(64) NOT NULL,
    station_id INT UNSIGNED NOT NULL,
    kind VARCHAR(16) NOT NULL DEFAULT 'dry',
    input_json JSON NULL,
    started_at BIGINT UNSIGNED NOT NULL,
    finish_at BIGINT UNSIGNED NOT NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'running',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_drugs_processes_slot (kind, station_id),
    INDEX idx_drugs_processes_owner (owner_cid)
)]] },
    { name = '0042 palm6_drugs_dealers', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_drugs_dealers` (
    owner_cid          VARCHAR(64) NOT NULL PRIMARY KEY,
    hired_at           BIGINT UNSIGNED NOT NULL,
    last_tick_at       BIGINT UNSIGNED NOT NULL,
    stash_json         JSON NULL,
    dirty_owed         INT UNSIGNED NOT NULL DEFAULT 0,
    dirty_earned_total BIGINT UNSIGNED NOT NULL DEFAULT 0,
    day_key            VARCHAR(10) NOT NULL DEFAULT '',
    day_dirty          INT UNSIGNED NOT NULL DEFAULT 0,
    created_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)]] },
    -- 0039: base drugs tables (see sql/0039_drugs.sql). Registered here because
    -- 0042 palm6_drugs_dealers (above) and the live palm6_drugs resource assume
    -- these exist; without them a rebuild-from-dbmigrate DB would have no drugs
    -- layer. IF NOT EXISTS -> no-op where prod already applied 0039.
    { name = '0039 palm6_drugs_plants', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_drugs_plants` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    owner_cid VARCHAR(64) NOT NULL,
    coord_x DOUBLE NOT NULL,
    coord_y DOUBLE NOT NULL,
    coord_z DOUBLE NOT NULL,
    strain VARCHAR(32) NOT NULL,
    soil_tier TINYINT UNSIGNED NOT NULL DEFAULT 2,
    planted_at BIGINT UNSIGNED NOT NULL,
    ready_at BIGINT UNSIGNED NOT NULL,
    water_level TINYINT UNSIGNED NOT NULL DEFAULT 100,
    watered_at BIGINT UNSIGNED NOT NULL,
    additives JSON NULL,
    neglected TINYINT(1) NOT NULL DEFAULT 0,
    stage VARCHAR(16) NOT NULL DEFAULT 'growing',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_drugs_plants_owner (owner_cid),
    INDEX idx_drugs_plants_plot (coord_x, coord_y, coord_z)
)]] },
    { name = '0039 palm6_drugs_recipes', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_drugs_recipes` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    owner_cid VARCHAR(64) NOT NULL,
    brand VARCHAR(48) NOT NULL,
    base VARCHAR(32) NOT NULL,
    steps_json JSON NULL,
    effects_json JSON NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_drugs_recipes_owner_brand (owner_cid, brand)
)]] },
    { name = '0039 palm6_drugs_progression', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_drugs_progression` (
    owner_cid VARCHAR(64) NOT NULL PRIMARY KEY,
    xp INT UNSIGNED NOT NULL DEFAULT 0,
    rank_tier INT UNSIGNED NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
)]] },
    { name = '0039 palm6_drugs_sales', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_drugs_sales` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    channel VARCHAR(16) NOT NULL DEFAULT 'npc',
    brand VARCHAR(48) NULL,
    base VARCHAR(32) NULL,
    quality TINYINT UNSIGNED NOT NULL DEFAULT 2,
    units INT UNSIGNED NOT NULL,
    gross INT UNSIGNED NOT NULL,
    cut_paid INT UNSIGNED NOT NULL DEFAULT 0,
    net_dirty INT UNSIGNED NOT NULL,
    region VARCHAR(48) NULL,
    flagged TINYINT(1) NOT NULL DEFAULT 0,
    evidence_case_id INT UNSIGNED NULL DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_drugs_sales_citizen_day (citizenid, created_at)
)]] },
    -- 0041: base gang tables (see sql/0041_gangs.sql). MUST be registered before
    -- the 0043 ALTER/index and the 0049 UPDATE below, both of which reference
    -- palm6_gangs — the palm6_gangs resource itself creates no tables. IF NOT
    -- EXISTS -> no-op where prod already applied 0041.
    { name = '0041 palm6_gangs', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_gangs` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(32) NOT NULL,
    tag VARCHAR(8) NOT NULL,
    leader_cid VARCHAR(64) NOT NULL,
    vault_balance BIGINT UNSIGNED NOT NULL DEFAULT 0,
    rep INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_palm6_gang_name (name),
    UNIQUE KEY uniq_palm6_gang_tag (tag),
    INDEX idx_palm6_gang_leader (leader_cid)
)]] },
    { name = '0041 palm6_gang_members', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_gang_members` (
    citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
    gang_id INT UNSIGNED NOT NULL,
    rank TINYINT UNSIGNED NOT NULL DEFAULT 1,
    name VARCHAR(64) NULL DEFAULT NULL,
    joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_gang_members_gang (gang_id)
)]] },
    { name = '0041 palm6_gang_vault_log', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_gang_vault_log` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    gang_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    action VARCHAR(16) NOT NULL,
    amount BIGINT UNSIGNED NOT NULL,
    balance_after BIGINT UNSIGNED NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_gang_vault_gang (gang_id, created_at)
)]] },
    { name = '0043 palm6_gangs web columns', sql = [[
ALTER TABLE `palm6_gangs`
    ADD COLUMN IF NOT EXISTS `logo_url`    VARCHAR(512) NULL AFTER `rep`,
    ADD COLUMN IF NOT EXISTS `description` VARCHAR(500) NULL AFTER `logo_url`,
    ADD COLUMN IF NOT EXISTS `color`       VARCHAR(9)   NULL AFTER `description`,
    ADD COLUMN IF NOT EXISTS `updated_at`  TIMESTAMP    NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP AFTER `created_at`
]] },
    { name = '0043 idx_palm6_gangs_rep', sql = [[CREATE INDEX IF NOT EXISTS `idx_palm6_gangs_rep` ON `palm6_gangs` (`rep`)]] },
    { name = '0043 idx_palm6_gangs_vault', sql = [[CREATE INDEX IF NOT EXISTS `idx_palm6_gangs_vault` ON `palm6_gangs` (`vault_balance`)]] },
    { name = '0044 palm6_gang_web_tokens', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_gang_web_tokens` (
    token       VARCHAR(64)     NOT NULL PRIMARY KEY,
    gang_id     INT UNSIGNED    NOT NULL,
    created_at  BIGINT UNSIGNED NOT NULL,
    expires_at  BIGINT UNSIGNED NOT NULL,
    used_at     BIGINT UNSIGNED NULL,
    created_at_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)]] },
    { name = '0044 idx_palm6_gang_web_tokens_gang', sql = [[CREATE INDEX IF NOT EXISTS `idx_palm6_gang_web_tokens_gang` ON `palm6_gang_web_tokens` (`gang_id`)]] },
    { name = '0045 palm6_onboarding starter-grant flags', sql = [[
ALTER TABLE `palm6_onboarding`
    ADD COLUMN IF NOT EXISTS starter_vehicle_granted TINYINT(1) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS starter_outfit_granted  TINYINT(1) NOT NULL DEFAULT 0
]] },
    { name = '0046 palm6_market_state', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_market_state` (
    commodity VARCHAR(64) NOT NULL PRIMARY KEY,
    price     DOUBLE      NOT NULL,
    last_ts   BIGINT      NOT NULL
)]] },
    { name = '0046 palm6_market_trades', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_market_trades` (
    id        INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    commodity VARCHAR(64) NOT NULL,
    qty       INT NOT NULL,
    total     INT NOT NULL,
    ts        BIGINT NOT NULL,
    INDEX idx_palm6_market_trades_cid (citizenid),
    INDEX idx_palm6_market_trades_commodity (commodity)
)]] },
    { name = '0047 palm6_yard_sentence', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_yard_sentence` (
    citizenid        VARCHAR(64) NOT NULL PRIMARY KEY,
    baseline_minutes INT         NOT NULL DEFAULT 0,
    shaved_minutes   INT         NOT NULL DEFAULT 0,
    updated_at       BIGINT      NOT NULL DEFAULT 0
)]] },
    { name = '0047 palm6_yard_labor', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_yard_labor` (
    citizenid       VARCHAR(64) NOT NULL PRIMARY KEY,
    last_task_at    BIGINT      NOT NULL DEFAULT 0,
    tasks_completed INT         NOT NULL DEFAULT 0
)]] },
    { name = '0047 palm6_yard_commissary_log', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_yard_commissary_log` (
    citizenid VARCHAR(64) NOT NULL,
    item      VARCHAR(64) NOT NULL,
    ymd       INT         NOT NULL,
    qty       INT         NOT NULL DEFAULT 0,
    PRIMARY KEY (citizenid, item, ymd)
)]] },
    { name = '0047 palm6_yard_bail', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_yard_bail` (
    id               INT         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid        VARCHAR(64) NOT NULL,
    amount           INT         NOT NULL,
    released_minutes INT         NOT NULL,
    rearrest_until   BIGINT      NOT NULL DEFAULT 0,
    created_at       BIGINT      NOT NULL DEFAULT 0,
    INDEX idx_palm6_yard_bail_cid (citizenid)
)]] },
    { name = '0048 palm6_pulse_windows', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_pulse_windows` (
    id            INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    kind          VARCHAR(32)  NOT NULL,
    domain        VARCHAR(16)  NOT NULL,
    modifier      DOUBLE       NOT NULL,
    target        VARCHAR(64)  NULL,
    reason        VARCHAR(128) NOT NULL,
    online_start  INT          NOT NULL DEFAULT 0,
    started_at    BIGINT       NOT NULL,
    ends_at       BIGINT       NOT NULL,
    INDEX idx_palm6_pulse_windows_ends (ends_at)
)]] },
    { name = '0048 palm6_pulse_checkins', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_pulse_checkins` (
    id          INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    window_id   INT          NOT NULL,
    citizenid   VARCHAR(64)  NOT NULL,
    ts          BIGINT       NOT NULL,
    UNIQUE KEY uq_palm6_pulse_checkin (window_id, citizenid),
    INDEX idx_palm6_pulse_checkins_cid (citizenid)
)]] },
    { name = '0048 palm6_pulse_streaks', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_pulse_streaks` (
    citizenid       VARCHAR(64) NOT NULL PRIMARY KEY,
    streak          INT         NOT NULL DEFAULT 0,
    best_streak     INT         NOT NULL DEFAULT 0,
    pulse_points    INT         NOT NULL DEFAULT 0,
    last_window_id  INT         NOT NULL DEFAULT 0,
    updated_at      BIGINT      NOT NULL DEFAULT 0
)]] },
    -- 0049: reconcile turf ownership after the gang-identity change (turf now
    -- keys on palm6_gangs.name). Idempotent — only nulls turf whose owner_gang
    -- is NOT a current palm6_gangs name, so it is safe to re-run every boot and
    -- also auto-releases turf held by a since-disbanded gang. See sql/0049.
    { name = '0049 palm6_turf identity reset', sql = [[
UPDATE `palm6_turf`
   SET `owner_gang` = NULL, `captured_by` = NULL, `captured_at` = NULL
 WHERE `owner_gang` IS NOT NULL
   AND `owner_gang` NOT IN (SELECT `name` FROM `palm6_gangs`)]] },
    -- 0050: pickup-visited flag for courier (see sql/0050). Idempotent ALTER.
    { name = '0050 courier picked_up column', sql = [[
ALTER TABLE `courier_postings` ADD COLUMN IF NOT EXISTS `picked_up` TINYINT NOT NULL DEFAULT 0]] },
    -- 0051: persist turf rep-mint cooldown (see sql/0051). Idempotent ALTER.
    { name = '0051 turf rep_at column', sql = [[
ALTER TABLE `palm6_turf` ADD COLUMN IF NOT EXISTS `rep_at` BIGINT NOT NULL DEFAULT 0]] },
    -- 0052: persist counterfeit fence daily quota (see sql/0052).
    { name = '0052 counterfeit_fence_quota', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_counterfeit_fence_quota` (
    `cid`      VARCHAR(64) NOT NULL,
    `fence_id` VARCHAR(64) NOT NULL,
    `day_key`  VARCHAR(8)  NOT NULL,
    `cnt`      INT         NOT NULL DEFAULT 0,
    PRIMARY KEY (`cid`, `fence_id`, `day_key`)
)]] },
    -- 0053: persist pumpcoin billboards (see sql/0053).
    { name = '0053 pumpcoin_billboards', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_pumpcoin_billboards` (
    `id`         INT         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    `coord_x`    DOUBLE      NOT NULL,
    `coord_y`    DOUBLE      NOT NULL,
    `coord_z`    DOUBLE      NOT NULL,
    `label`      VARCHAR(64) NOT NULL,
    `expires_at` BIGINT      NOT NULL,
    INDEX `idx_palm6_pumpcoin_billboards_exp` (`expires_at`)
)]] },
    -- 0066: Def Jam Fight Club (Phase 0). Registers the BASE fightclub tables
    -- (0028 was never added here — a fresh-DB rebuild had no fightclub layer and
    -- the 0054 ALTERs below FAILed on a missing table) BEFORE the additive
    -- columns + progression/unlock/daily/pve tables. All IF NOT EXISTS -> no-op
    -- on prod where 0028/0054 already ran. See sql/0066_fightclub_defjam.sql.
    -- rep_awarded DEFAULT 1 backfills existing resolved matches as already-awarded
    -- so the progression boot reconcile never re-grants rep on payment history.
    { name = '0066 fc base matches', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_fightclub_matches` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    fighter1_citizenid VARCHAR(64) NOT NULL,
    fighter1_name VARCHAR(100) NOT NULL DEFAULT '',
    fighter2_citizenid VARCHAR(64) NOT NULL,
    fighter2_name VARCHAR(100) NOT NULL DEFAULT '',
    status ENUM('betting','live','resolved') NOT NULL DEFAULT 'betting',
    winner_citizenid VARCHAR(64) DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    betting_ends_at TIMESTAMP NULL DEFAULT NULL,
    live_started_at TIMESTAMP NULL DEFAULT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_fightclub_matches_status (status),
    INDEX idx_palm6_fightclub_matches_f1 (fighter1_citizenid),
    INDEX idx_palm6_fightclub_matches_f2 (fighter2_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0066 fc base bets', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_fightclub_bets` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    match_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    fighter TINYINT UNSIGNED NOT NULL,
    amount INT UNSIGNED NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_palm6_fightclub_bet (match_id, citizenid),
    INDEX idx_palm6_fightclub_bets_match (match_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0066 fc matches defjam columns', sql = [[
ALTER TABLE `palm6_fightclub_matches`
    ADD COLUMN IF NOT EXISTS `style1`         VARCHAR(24) NULL,
    ADD COLUMN IF NOT EXISTS `style2`         VARCHAR(24) NULL,
    ADD COLUMN IF NOT EXISTS `fighter1_model` VARCHAR(48) NULL,
    ADD COLUMN IF NOT EXISTS `fighter2_model` VARCHAR(48) NULL,
    ADD COLUMN IF NOT EXISTS `method`         VARCHAR(16) NULL,
    ADD COLUMN IF NOT EXISTS `entry_pot`      INT     NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `entry_paid1`    TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `entry_paid2`    TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `rep_awarded`    TINYINT NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS `is_pve`         TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `cpu_tier`       TINYINT NULL,
    ADD COLUMN IF NOT EXISTS `cpu_fighter`    VARCHAR(48) NULL]] },
    { name = '0066 fc progression', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_fc_progression` (
    citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
    rep INT NOT NULL DEFAULT 0,
    wins INT NOT NULL DEFAULT 0,
    losses INT NOT NULL DEFAULT 0,
    rank_tier INT NOT NULL DEFAULT 0,
    pve_wins INT NOT NULL DEFAULT 0,
    pve_losses INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0066 fc unlocks', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_fc_unlocks` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    unlock_id VARCHAR(48) NOT NULL,
    unlocked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_fc_unlock (citizenid, unlock_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0066 fc daily', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_fc_daily` (
    citizenid VARCHAR(64) NOT NULL,
    day_bucket VARCHAR(10) NOT NULL,
    pvp_rep_wins INT NOT NULL DEFAULT 0,
    pve_rep_wins INT NOT NULL DEFAULT 0,
    distinct_opponents INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (citizenid, day_bucket)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0066 fc pve cooldowns', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_fc_pve_cooldowns` (
    citizenid VARCHAR(64) NOT NULL,
    cpu_tier TINYINT NOT NULL,
    beaten_at BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (citizenid, cpu_tier)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    -- 0054: recoverable fightclub settlement (see sql/0054). Idempotent ALTERs.
    -- `paid` (per-bet) + `purse_paid` (per-match) are claim-before-credit
    -- idempotency flags; `settled` marks a match whose payout fully completed.
    -- A crash mid-payout leaves status='resolved' AND settled=0, which the
    -- fightclub boot reconcile re-drives without ever double-paying.
    { name = '0054 fightclub bets.paid', sql = [[
ALTER TABLE `palm6_fightclub_bets` ADD COLUMN IF NOT EXISTS `paid` TINYINT NOT NULL DEFAULT 0]] },
    { name = '0054 fightclub matches.purse_paid', sql = [[
ALTER TABLE `palm6_fightclub_matches` ADD COLUMN IF NOT EXISTS `purse_paid` TINYINT NOT NULL DEFAULT 0]] },
    -- settled DEFAULT 1: backfills existing resolved matches as already-settled
    -- so the boot reconcile never re-pays payment history on the first restart.
    -- resolveMatch resets settled=0 at the live->resolved flip for new matches.
    { name = '0054 fightclub matches.settled', sql = [[
ALTER TABLE `palm6_fightclub_matches` ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 1]] },
    -- 0057: recoverable insurance claim payout (see palm6_insurance). `credited_at`
    -- is a BIGINT used purely as a 0/nonzero claim flag (creditClaim claims it
    -- WHERE credited_at = 0 before the bank credit). DEFAULT 1 backfills EXISTING
    -- terminal (paid/flagged_paid) rows as already-credited so the boot reconcile
    -- (WHERE credited_at = 0) never re-pays payment history on the first restart.
    -- The 30s sweep's terminal-flip resets credited_at = 0 for each genuinely NEW
    -- paid claim, keeping a post-deploy crash recoverable.
    { name = '0057 insurance claims.credited_at', sql = [[
ALTER TABLE `palm6_insurance_claims` ADD COLUMN IF NOT EXISTS `credited_at` BIGINT NOT NULL DEFAULT 1]] },
    { name = '0057 insurance claims uncredited index', sql = [[
CREATE INDEX IF NOT EXISTS `idx_insurance_claims_uncredited` ON `palm6_insurance_claims` (`credited_at`, `status`)]] },
    -- 0062: recoverable flashdrop consignment settlement (see sql/0062).
    -- Both DEFAULT 1 so existing sold listings are backfilled as paid+settled
    -- (boot reconcile skips them); the buy path resets both to 0 at reserve.
    { name = '0062 flashdrop listings.buyer_paid', sql = [[
ALTER TABLE `palm6_flashdrop_listings` ADD COLUMN IF NOT EXISTS `buyer_paid` TINYINT NOT NULL DEFAULT 1]] },
    { name = '0062 flashdrop listings.settled', sql = [[
ALTER TABLE `palm6_flashdrop_listings` ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 1]] },
    -- 0063: recoverable pumpcoin delist settlement (see sql/0063).
    { name = '0063 pumpcoin holdings.settled', sql = [[
ALTER TABLE `palm6_pumpcoin_holdings` ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 0]] },
    { name = '0063 pumpcoin coins.delist_pool', sql = [[
ALTER TABLE `palm6_pumpcoin_coins` ADD COLUMN IF NOT EXISTS `delist_pool` BIGINT NULL DEFAULT NULL]] },
    { name = '0063 pumpcoin coins.delist_supply', sql = [[
ALTER TABLE `palm6_pumpcoin_coins` ADD COLUMN IF NOT EXISTS `delist_supply` INT UNSIGNED NULL DEFAULT NULL]] },
    -- 0060: recoverable clout brand-deal cashout (see sql/0060). `paid` DEFAULT 1
    -- backfills existing claimed deals as already-paid (boot reconcile skips them);
    -- the milestone INSERT writes paid=0 explicitly so new deals stay recoverable.
    { name = '0060 clout deals.paid', sql = [[
ALTER TABLE `palm6_clout_deals` ADD COLUMN IF NOT EXISTS `paid` TINYINT NOT NULL DEFAULT 1]] },
    { name = '0060 clout deals unpaid index', sql = [[
CREATE INDEX IF NOT EXISTS `idx_clout_deals_unpaid` ON `palm6_clout_deals` (`paid`, `claimed_at`)]] },
    -- 0055-0061: recoverable settlement flags for the bank-money payout resolvers
    -- (bounty/courier/insurance/ransom/lottery/season). Each is DEFAULT 1 so
    -- EXISTING terminal rows (already paid under the old code) are backfilled as
    -- already-settled and the per-resource boot reconcile (WHERE flag=0) never
    -- re-pays payment history on the first restart after deploy; each resource's
    -- terminal-flip (or the season reward INSERT) resets the flag to 0 so records
    -- reaching a terminal state AFTER deploy stay recoverable. ADD COLUMN IF NOT
    -- EXISTS runs the backfill exactly once. See sql/0055-0061 + each resource's
    -- settle*/reconcile* functions.
    { name = '0055 bounty contracts.settled', sql = [[
ALTER TABLE `palm6_bounty_contracts` ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 1]] },
    { name = '0056 courier postings.settled', sql = [[
ALTER TABLE `courier_postings` ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 1]] },
    { name = '0057 insurance claims.credited_at', sql = [[
ALTER TABLE `palm6_insurance_claims` ADD COLUMN IF NOT EXISTS `credited_at` BIGINT NOT NULL DEFAULT 1]] },
    { name = '0058 ransom cases.payout_credited', sql = [[
ALTER TABLE `palm6_ransom_cases` ADD COLUMN IF NOT EXISTS `payout_credited` TINYINT NOT NULL DEFAULT 1]] },
    { name = '0059 lottery draws.paid', sql = [[
ALTER TABLE `palm6_lottery_draws` ADD COLUMN IF NOT EXISTS `paid` TINYINT NOT NULL DEFAULT 1]] },
    { name = '0061 season_rewards.paid', sql = [[
ALTER TABLE `palm6_season_rewards` ADD COLUMN IF NOT EXISTS `paid` TINYINT NOT NULL DEFAULT 1]] },
    -- 0064: insurance plan tier (see sql/0064). DEFAULT 'standard' backfills
    -- pre-tier policies to the plan that reproduces the old flat behaviour.
    { name = '0064 insurance policies.tier', sql = [[
ALTER TABLE `palm6_insurance_policies` ADD COLUMN IF NOT EXISTS `tier` VARCHAR(16) NOT NULL DEFAULT 'standard']] },
    -- 0065: allow status='claimed' (see sql/0065). The retire-on-claim UPDATE
    -- writes 'claimed', which the original ENUM('active','lapsed','cancelled')
    -- rejected under strict SQL mode -> the retire silently failed and left a
    -- repeatable claim faucet. Adding the member at the end is INSTANT + idempotent.
    { name = '0065 insurance policies.status +claimed', sql = [[
ALTER TABLE `palm6_insurance_policies` MODIFY COLUMN `status` ENUM('active','lapsed','cancelled','claimed') NOT NULL DEFAULT 'active']] },
    -- 0067: palm6_racing (street racing, Phase 0 rep-only). Leaderboard aggregate +
    -- a per-finish results log (the log backs the rolling-24h DailyRepCap count).
    -- No money columns — Phase 0 is rep-only. Both idempotent CREATE IF NOT EXISTS.
    { name = '0067 racing progression', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_racing_progression` (
    citizenid VARCHAR(64) NOT NULL,
    name VARCHAR(64) NULL,
    rep INT NOT NULL DEFAULT 0,
    wins INT NOT NULL DEFAULT 0,
    races INT NOT NULL DEFAULT 0,
    rank_tier TINYINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0067 racing results', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_racing_results` (
    id INT NOT NULL AUTO_INCREMENT,
    citizenid VARCHAR(64) NOT NULL,
    route_id VARCHAR(48) NOT NULL,
    place TINYINT NOT NULL,
    rep INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_racing_results_cid_time (citizenid, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    -- 0068: palm6_business (player-owned businesses, Phase 0). A registry, a
    -- pooled BANK account, an employee roster, and a ledger. No money columns that
    -- can mint: account_balance is pooled real money, supply_units is a
    -- clean-money cost basis for the capped NPC-income faucet, day_npc_income is
    -- the per-business daily cap counter. All three idempotent CREATE IF NOT EXISTS.
    { name = '0068 palm6_businesses', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_businesses` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    owner_cid VARCHAR(64) NOT NULL,
    name VARCHAR(48) NOT NULL,
    biz_type VARCHAR(24) NOT NULL,
    account_balance BIGINT UNSIGNED NOT NULL DEFAULT 0,
    supply_units INT UNSIGNED NOT NULL DEFAULT 0,
    day_key VARCHAR(10) NOT NULL DEFAULT '',
    day_npc_income INT UNSIGNED NOT NULL DEFAULT 0,
    -- Crash-recoverable payout marker (withdraw/payroll): the server debits the
    -- account and stamps a single pending payout here in one statement, then
    -- claim-before-credits it to the payee's bank; reconcilePending() re-drives it
    -- on boot. WITHOUT these three, every withdraw and payroll SQL-errors.
    pending_cid VARCHAR(64) NULL,
    pending_amount BIGINT UNSIGNED NOT NULL DEFAULT 0,
    pending_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_palm6_business_name (name),
    INDEX idx_palm6_business_owner (owner_cid),
    INDEX idx_palm6_business_pending (pending_amount)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0068 palm6_business_members', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_business_members` (
    citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
    business_id INT UNSIGNED NOT NULL,
    role TINYINT UNSIGNED NOT NULL DEFAULT 1,
    wage INT UNSIGNED NOT NULL DEFAULT 0,
    clocked_in TINYINT(1) NOT NULL DEFAULT 0,
    last_serve_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
    name VARCHAR(64) NULL,
    hired_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_business_members_biz (business_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0068 palm6_business_ledger', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_business_ledger` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    business_id INT UNSIGNED NOT NULL,
    actor_cid VARCHAR(64) NOT NULL,
    action VARCHAR(16) NOT NULL,
    amount BIGINT NOT NULL,
    balance_after BIGINT UNSIGNED NOT NULL,
    memo VARCHAR(128) NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_business_ledger_biz (business_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    -- Backfill the crash-recoverable payout columns for any DB where an earlier
    -- 0068 created palm6_businesses without them (the CREATE above now includes
    -- them for fresh installs; this ALTER is the idempotent catch-up so withdraw
    -- and payroll never hit a missing-column error).
    { name = '0069 palm6_businesses pending payout columns', sql = [[
ALTER TABLE `palm6_businesses`
    ADD COLUMN IF NOT EXISTS `pending_cid`    VARCHAR(64)     NULL              AFTER `day_npc_income`,
    ADD COLUMN IF NOT EXISTS `pending_amount` BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `pending_cid`,
    ADD COLUMN IF NOT EXISTS `pending_at`     BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `pending_amount`]] },
    -- 0068 recoverable-payout columns via ALTER (NOT only the CREATE above): the
    -- CREATE TABLE IF NOT EXISTS is a no-op on any DB where palm6_businesses was
    -- already created by an earlier boot (510b13e), so it would NOT add these
    -- columns there — mirroring the recoverability sweep's ALTER pattern
    -- (0054-0063) guarantees the pending marker lands on an existing table too.
    -- DEFAULT 0 on pending_amount is load-bearing (debitAccountWithPending's
    -- WHERE pending_amount = 0 guard must match on rows that predate the column).
    { name = '0068 business pending_cid', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `pending_cid` VARCHAR(64) NULL]] },
    { name = '0068 business pending_amount', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `pending_amount` BIGINT UNSIGNED NOT NULL DEFAULT 0]] },
    { name = '0068 business pending_at', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `pending_at` BIGINT UNSIGNED NOT NULL DEFAULT 0]] },
    { name = '0068 business pending index', sql = [[
CREATE INDEX IF NOT EXISTS `idx_palm6_business_pending` ON `palm6_businesses` (`pending_amount`)]] },
    -- 0009: the connect-gate `allowlist` table (see sql/0009_allowlist.sql). It was
    -- ONLY in the standalone sql file, never registered here — so on a fresh/rebuilt
    -- prod DB (which is not reachable from outside the panel network) it would be
    -- ABSENT, and palm6_allowlist's connect query would throw and HANG every join.
    -- Registered here so it always exists on boot. IF NOT EXISTS -> no-op where 0009
    -- already applied. (palm6_allowlist also now pcall-guards the read as a backstop.)
    -- 0008: palm6_eventguard's `event_violations` forensics table. Like 0009 below
    -- it previously existed ONLY in a standalone sql file (sql/0008_security_events
    -- .sql), so a fresh/rebuilt prod DB would not have it — and the guard's INSERT
    -- then threw on every violation. Registered here so it always exists on boot.
    -- (record() also pcall-guards the INSERT now, so a missing table can never
    -- break the drop/kick path.) IF NOT EXISTS -> no-op where 0008 already applied.
    { name = '0008 event_violations', sql = [[
CREATE TABLE IF NOT EXISTS `event_violations` (
    `id`         INT AUTO_INCREMENT PRIMARY KEY,
    `player_src` INT NOT NULL,
    `identifier` VARCHAR(100) DEFAULT NULL,
    `event_name` VARCHAR(100) NOT NULL,
    `reason`     VARCHAR(255) NOT NULL,
    `created_at` DATETIME NOT NULL,
    KEY `idx_event_time` (`event_name`, `created_at`),
    KEY `idx_identifier` (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0009 allowlist', sql = [[
CREATE TABLE IF NOT EXISTS `allowlist` (
    `id`         INT AUTO_INCREMENT PRIMARY KEY,
    `identifier` VARCHAR(100) NOT NULL UNIQUE,
    `note`       VARCHAR(255) DEFAULT NULL,
    `enabled`    TINYINT(1) NOT NULL DEFAULT 1,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    -- 0070: palm6_business Phase 1 — PHYSICAL STOREFRONTS. Adds a map location +
    -- blip appearance to an existing business so it becomes a PLACE on the map, not
    -- just a menu. All columns nullable via ADD COLUMN IF NOT EXISTS (the 0068
    -- pending-column pattern) so a business with no storefront set behaves exactly
    -- like Phase 0. NO money columns here — storefronts touch presentation/location
    -- only; the account/faucet invariants are untouched. loc_h = heading (for a
    -- future greeter ped); blip_sprite/blip_color are owner cosmetics validated
    -- server-side against Config.Storefront allowlists before write.
    { name = '0070 business loc_x', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `loc_x` DOUBLE NULL]] },
    { name = '0070 business loc_y', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `loc_y` DOUBLE NULL]] },
    { name = '0070 business loc_z', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `loc_z` DOUBLE NULL]] },
    { name = '0070 business loc_h', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `loc_h` DOUBLE NULL]] },
    { name = '0070 business blip_sprite', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `blip_sprite` SMALLINT UNSIGNED NULL]] },
    { name = '0070 business blip_color', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `blip_color` TINYINT UNSIGNED NULL]] },
    { name = '0070 business loc index', sql = [[
CREATE INDEX IF NOT EXISTS `idx_palm6_business_loc` ON `palm6_businesses` (`loc_x`)]] },
    -- 0071: palm6_business Phase 1 — manager delegate payroll DAY-LOCK. A nullable
    -- per-member marker of the last UTC day they were paid; opPayroll only enforces
    -- it while Config.ManagerRole is on, so each member is paid at most once per
    -- period when delegated management is active (bounds a manager's payroll to the
    -- owner-authorised wage once/day — no repeat-payroll account drain). Nullable
    -- ADD COLUMN IF NOT EXISTS (0068 pending pattern); no effect while dark.
    { name = '0071 business_members last_payroll_day', sql = [[
ALTER TABLE `palm6_business_members` ADD COLUMN IF NOT EXISTS `last_payroll_day` VARCHAR(10) NULL]] },
    -- 0072: palm6_business robbery cooldown — the epoch a business's register was
    -- last cracked. opRob stamps + guards on it atomically (per-business cooldown).
    -- Nullable, ADD COLUMN IF NOT EXISTS (0068 pending pattern); no effect while the
    -- robbery feature is dark.
    { name = '0072 business last_robbed_at', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `last_robbed_at` BIGINT UNSIGNED NULL]] },
    -- 0073: palm6_business Starter Pack (the $29.99 store SKU) cosmetics. A
    -- per-Discord-ACCOUNT entitlement (granted by the Tebex -> bot -> web chain on
    -- purchase, or the admin grant command for testing) unlocks per-BUSINESS
    -- cosmetic fields: a custom storefront nameplate and a premium blip skin.
    -- Keyed by discord_id (not citizenid) because a purchase is account-level and
    -- can precede a character; every character the buyer owns benefits. Cosmetic
    -- ONLY: touches no money and never changes what a business earns. All inert
    -- unless Config.StarterPack.Enabled. Nullable/idempotent (0068 pattern).
    { name = '0073 business_entitlements table', sql = [[
CREATE TABLE IF NOT EXISTS `palm6_business_entitlements` (
    discord_id VARCHAR(32) NOT NULL,
    pack VARCHAR(24) NOT NULL,
    granted_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
    source VARCHAR(32) NOT NULL DEFAULT 'unknown',
    PRIMARY KEY (discord_id, pack)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { name = '0073 business nameplate', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `nameplate` VARCHAR(32) NULL]] },
    { name = '0073 business skin', sql = [[
ALTER TABLE `palm6_businesses` ADD COLUMN IF NOT EXISTS `skin` VARCHAR(24) NULL]] },
}

CreateThread(function()
    Wait(3000) -- let oxmysql establish its connection first
    print('[palm6_dbmigrate] ============================================')
    print('[palm6_dbmigrate] applying pending idempotent migrations...')
    local ok, fail = 0, 0
    for _, stmt in ipairs(STATEMENTS) do
        local success, err = pcall(function() MySQL.query.await(stmt.sql) end)
        if success then
            ok = ok + 1
            print(('[palm6_dbmigrate]   OK   %s'):format(stmt.name))
        else
            fail = fail + 1
            print(('[palm6_dbmigrate]   FAIL %s -> %s'):format(stmt.name, tostring(err)))
        end
    end
    -- verification: confirm the meth-lab-critical table exists
    local present = false
    local vok, vres = pcall(function() return MySQL.query.await("SHOW TABLES LIKE 'palm6_drugs_processes'") end)
    if vok and vres and #vres > 0 then present = true end
    print(('[palm6_dbmigrate] done: %d ok, %d failed. palm6_drugs_processes present = %s'):format(ok, fail, tostring(present)))
    print('[palm6_dbmigrate] SAFE TO REMOVE this resource now (all statements are IF NOT EXISTS).')
    print('[palm6_dbmigrate] ============================================')
end)
