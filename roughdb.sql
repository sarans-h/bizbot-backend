-- Single-file PostgreSQL DDL for BizBot-style multi-tenant platform
-- Assumptions:
--  - PostgreSQL 14+
--  - Multi-business per user (a user can be member/owner of many businesses)
--  - Credit management is ledger-based + maintained running balance on businesses (atomic, transparent)
--  - “Stateful architecture” supported via conversation state + event/audit log + optional metrics rollups
--
-- Run this file in order on an empty database.

-- =========================
-- 0) EXTENSIONS
-- =========================
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;    -- case-insensitive text for emails

-- =========================
-- 1) ENUMS
-- =========================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'membership_role') THEN
    CREATE TYPE membership_role AS ENUM ('owner', 'agent');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'subscription_tier_code') THEN
    CREATE TYPE subscription_tier_code AS ENUM ('free', 'pro', 'premium', 'enterprise');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'subscription_status') THEN
    CREATE TYPE subscription_status AS ENUM ('trialing', 'active', 'past_due', 'canceled', 'paused');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'conversation_status') THEN
    CREATE TYPE conversation_status AS ENUM ('ai_active', 'waiting_human', 'human_active', 'resolved');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'message_sender_type') THEN
    CREATE TYPE message_sender_type AS ENUM ('customer', 'ai', 'agent', 'system');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lead_source') THEN
    CREATE TYPE lead_source AS ENUM ('chatbot', 'manual', 'import', 'booking', 'email_campaign');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lead_status') THEN
    CREATE TYPE lead_status AS ENUM ('new', 'contacted', 'qualified', 'converted', 'lost');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'campaign_status') THEN
    CREATE TYPE campaign_status AS ENUM ('draft', 'scheduled', 'sending', 'sent', 'paused', 'canceled');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'recipient_status') THEN
    CREATE TYPE recipient_status AS ENUM ('pending', 'sent', 'opened', 'clicked', 'bounced', 'complained', 'unsubscribed');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'appointment_status') THEN
    CREATE TYPE appointment_status AS ENUM ('pending', 'confirmed', 'cancelled', 'completed', 'no_show', 'rescheduled');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'override_type') THEN
    CREATE TYPE override_type AS ENUM ('unavailable', 'custom_hours');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_type') THEN
    CREATE TYPE notification_type AS ENUM ('booking_confirmation', 'reminder_24h', 'reminder_1h', 'cancellation', 'reschedule');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_status') THEN
    CREATE TYPE notification_status AS ENUM ('sent', 'failed', 'bounced');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'credit_event_kind') THEN
    CREATE TYPE credit_event_kind AS ENUM (
      'grant',           -- admin grant / promo
      'purchase',        -- paid top-up
      'refund',          -- refund back to credits
      'consume_message', -- AI message consumption
      'consume_email',   -- email campaign send consumption
      'consume_other',   -- other consumption
      'adjustment'       -- manual adjustment
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'kb_item_type') THEN
    CREATE TYPE kb_item_type AS ENUM ('faq', 'policy', 'product', 'service', 'pricing', 'other');
  END IF;
END $$;

-- =========================
-- 2) CORE: USERS + BUSINESSES + MEMBERSHIPS
-- =========================

-- Platform user (can belong to multiple businesses)
CREATE TABLE IF NOT EXISTS app_users (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email              CITEXT NOT NULL UNIQUE,
  password_hash      TEXT NOT NULL,
  is_platform_admin  BOOLEAN NOT NULL DEFAULT FALSE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at      TIMESTAMPTZ NULL
);

-- Businesses (tenants)
CREATE TABLE IF NOT EXISTS businesses (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                     TEXT NOT NULL,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Subscription snapshot fields (authoritative is subscriptions table)
  current_tier             subscription_tier_code NOT NULL DEFAULT 'free',
  subscription_expires_at  TIMESTAMPTZ NULL,

  -- Encrypted secrets (store ciphertext; encryption managed in app/KMS)
  ai_api_key_encrypted     TEXT NULL,

  -- Credit balance maintained by credit_ledger trigger (do not update directly)
  credits_balance          BIGINT NOT NULL DEFAULT 0,

  -- Soft operational limits (tier logic enforced via trigger below)
  max_agent_logins_override INTEGER NULL
);

-- Memberships (owner/agents) — supports multiple businesses per user
CREATE TABLE IF NOT EXISTS business_memberships (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  user_id       UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,

  role          membership_role NOT NULL,

  -- Granular permissions (defaults handled in app; can be overridden here)
  permissions   JSONB NOT NULL DEFAULT '{}'::jsonb,

  is_active     BOOLEAN NOT NULL DEFAULT TRUE,

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (business_id, user_id)
);

-- Enforce single owner per business
CREATE UNIQUE INDEX IF NOT EXISTS ux_business_one_owner
  ON business_memberships (business_id)
  WHERE role = 'owner' AND is_active = TRUE;

CREATE INDEX IF NOT EXISTS ix_memberships_user
  ON business_memberships (user_id);

CREATE INDEX IF NOT EXISTS ix_memberships_business
  ON business_memberships (business_id);

-- =========================
-- 3) SUBSCRIPTION / TIERS (seat limits live here)
-- =========================
CREATE TABLE IF NOT EXISTS subscription_tiers (
  code                 subscription_tier_code PRIMARY KEY,
  display_name         TEXT NOT NULL,
  included_owner_seats INTEGER NOT NULL DEFAULT 1,
  included_agent_seats INTEGER NOT NULL DEFAULT 0,  -- free=2, pro=5, premium=20
  monthly_price_cents  INTEGER NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS subscriptions (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id          UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  tier_code            subscription_tier_code NOT NULL REFERENCES subscription_tiers(code),
  status               subscription_status NOT NULL DEFAULT 'active',

  started_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  current_period_start TIMESTAMPTZ NOT NULL DEFAULT now(),
  current_period_end   TIMESTAMPTZ NULL,

  -- Optional add-ons
  extra_agent_seats    INTEGER NOT NULL DEFAULT 0,

  provider             TEXT NULL,        -- e.g., 'stripe'
  provider_sub_id      TEXT NULL,        -- subscription identifier in provider
  metadata             JSONB NOT NULL DEFAULT '{}'::jsonb,

  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_subscriptions_business
  ON subscriptions (business_id);

CREATE INDEX IF NOT EXISTS ix_subscriptions_business_status
  ON subscriptions (business_id, status);

-- =========================
-- 4) BUSINESS SETTINGS + KNOWLEDGE BASE
-- =========================
CREATE TABLE IF NOT EXISTS business_settings (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id             UUID NOT NULL UNIQUE REFERENCES businesses(id) ON DELETE CASCADE,

  chatbot_config          JSONB NOT NULL DEFAULT '{}'::jsonb,  -- theme/logo/welcome, etc.
  email_signature         TEXT NULL,
  auto_response_enabled   BOOLEAN NOT NULL DEFAULT TRUE,

  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Scalable KB: store multiple items instead of one large JSON blob
CREATE TABLE IF NOT EXISTS business_kb_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  item_type     kb_item_type NOT NULL DEFAULT 'other',
  title         TEXT NOT NULL,
  content       TEXT NOT NULL,                 -- plain text or markdown
  source        TEXT NULL,                     -- url/file/import name
  tags          TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_kb_items_business
  ON business_kb_items (business_id);

CREATE INDEX IF NOT EXISTS ix_kb_items_tags
  ON business_kb_items USING GIN (tags);

-- =========================
-- 5) CONTACTS (LEADS/CUSTOMERS) + CONVERSATIONS + MESSAGES
-- =========================

-- Unified contact table (replaces separate "leads" vs "customers")
CREATE TABLE IF NOT EXISTS contacts (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id    UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,

  email          CITEXT NULL,
  name           TEXT NULL,
  phone          TEXT NULL,

  source         lead_source NOT NULL DEFAULT 'manual',
  status         lead_status NOT NULL DEFAULT 'new',
  custom_fields  JSONB NOT NULL DEFAULT '{}'::jsonb,

  last_contacted_at TIMESTAMPTZ NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Deduplicate per business when email exists
  CONSTRAINT uq_contacts_business_email UNIQUE (business_id, email)
);

CREATE INDEX IF NOT EXISTS ix_contacts_business
  ON contacts (business_id);

CREATE INDEX IF NOT EXISTS ix_contacts_email
  ON contacts (email);

CREATE TABLE IF NOT EXISTS conversations (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,

  contact_id          UUID NULL REFERENCES contacts(id) ON DELETE SET NULL,
  customer_email      CITEXT NULL,  -- capture even if not yet verified/linked
  customer_name       TEXT NULL,

  status              conversation_status NOT NULL DEFAULT 'ai_active',

  assigned_agent_membership_id UUID NULL REFERENCES business_memberships(id) ON DELETE SET NULL,

  -- Stateful fields (AI/human handoff, routing, etc.)
  state              JSONB NOT NULL DEFAULT '{}'::jsonb,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_conversations_business_updated
  ON conversations (business_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS ix_conversations_business_status
  ON conversations (business_id, status);

CREATE INDEX IF NOT EXISTS ix_conversations_customer_email
  ON conversations (business_id, customer_email);

CREATE TABLE IF NOT EXISTS messages (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,

  sender_type      message_sender_type NOT NULL,
  sender_membership_id UUID NULL REFERENCES business_memberships(id) ON DELETE SET NULL,

  content          TEXT NOT NULL,
  metadata         JSONB NOT NULL DEFAULT '{}'::jsonb, -- tokens/model/latency/tool calls, etc.

  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_messages_conversation_created
  ON messages (conversation_id, created_at);

-- Optional: separate AI usage facts for reporting (denormalized-friendly)
CREATE TABLE IF NOT EXISTS message_ai_usage (
  message_id        UUID PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
  business_id        UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  model             TEXT NULL,
  prompt_tokens     INTEGER NULL,
  completion_tokens INTEGER NULL,
  total_tokens      INTEGER NULL,
  latency_ms        INTEGER NULL,
  credits_consumed  BIGINT NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_message_ai_usage_business_created
  ON message_ai_usage (business_id, created_at);

-- =========================
-- 6) CREDIT MANAGEMENT (LEDGER + ATOMIC BALANCE UPDATES)
-- =========================
CREATE TABLE IF NOT EXISTS credit_ledger (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,

  kind            credit_event_kind NOT NULL,
  delta           BIGINT NOT NULL, -- + adds credits, - consumes credits
  balance_after   BIGINT NULL,     -- set by trigger for transparency

  action_type     TEXT NOT NULL,   -- e.g. 'ai_message', 'email_send', 'admin_grant'
  reference_id    UUID NULL,       -- message_id, campaign_id, etc.
  reference_table TEXT NULL,       -- 'messages', 'email_campaigns', ...

  metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_credit_ledger_business_created
  ON credit_ledger (business_id, created_at DESC);

-- Idempotency: prevent double-charging when reference provided
CREATE UNIQUE INDEX IF NOT EXISTS ux_credit_ledger_idempotency
  ON credit_ledger (business_id, action_type, reference_id)
  WHERE reference_id IS NOT NULL;

-- =========================
-- 7) EMAIL CAMPAIGNS
-- =========================
CREATE TABLE IF NOT EXISTS email_campaigns (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,

  name          TEXT NOT NULL,
  subject       TEXT NOT NULL,
  html_content  TEXT NOT NULL,

  status        campaign_status NOT NULL DEFAULT 'draft',
  scheduled_at  TIMESTAMPTZ NULL,

  sent_count    INTEGER NOT NULL DEFAULT 0,
  open_rate     NUMERIC(6,4) NULL,
  click_rate    NUMERIC(6,4) NULL,

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_email_campaigns_business_status
  ON email_campaigns (business_id, status);

CREATE TABLE IF NOT EXISTS campaign_recipients (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id   UUID NOT NULL REFERENCES email_campaigns(id) ON DELETE CASCADE,
  contact_id    UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,

  status        recipient_status NOT NULL DEFAULT 'pending',
  sent_at       TIMESTAMPTZ NULL,

  provider_message_id TEXT NULL,  -- e.g. SendGrid id

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (campaign_id, contact_id)
);

CREATE INDEX IF NOT EXISTS ix_campaign_recipients_campaign_status
  ON campaign_recipients (campaign_id, status);

-- Detailed event log (open/click/bounce) for analytics
CREATE TABLE IF NOT EXISTS email_events (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  campaign_id         UUID NULL REFERENCES email_campaigns(id) ON DELETE SET NULL,
  recipient_id        UUID NULL REFERENCES campaign_recipients(id) ON DELETE SET NULL,

  event_type          TEXT NOT NULL, -- 'sent','delivered','open','click','bounce',...
  event_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload             JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS ix_email_events_business_event_at
  ON email_events (business_id, event_at DESC);

-- =========================
-- 8) CALENDAR + AVAILABILITY + APPOINTMENTS
-- =========================
CREATE TABLE IF NOT EXISTS calendar_settings (
  id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id                   UUID NOT NULL UNIQUE REFERENCES businesses(id) ON DELETE CASCADE,

  owner_only_visible            BOOLEAN NOT NULL DEFAULT TRUE,
  timezone                      TEXT NOT NULL DEFAULT 'UTC',

  buffer_time_minutes           INTEGER NOT NULL DEFAULT 15,
  min_booking_notice_hours      INTEGER NOT NULL DEFAULT 24,
  max_booking_days_ahead        INTEGER NOT NULL DEFAULT 30,
  meeting_duration_minutes      INTEGER NOT NULL DEFAULT 30,

  google_calendar_connected     BOOLEAN NOT NULL DEFAULT FALSE,
  google_calendar_id            TEXT NULL,
  google_refresh_token_encrypted TEXT NULL,
  auto_create_google_meet       BOOLEAN NOT NULL DEFAULT TRUE,

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_calendar_buffer_nonneg CHECK (buffer_time_minutes >= 0),
  CONSTRAINT ck_calendar_notice_nonneg CHECK (min_booking_notice_hours >= 0),
  CONSTRAINT ck_calendar_max_days_positive CHECK (max_booking_days_ahead > 0),
  CONSTRAINT ck_calendar_duration_positive CHECK (meeting_duration_minutes > 0)
);

CREATE TABLE IF NOT EXISTS availability_slots (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  calendar_settings_id  UUID NOT NULL REFERENCES calendar_settings(id) ON DELETE CASCADE,

  day_of_week           SMALLINT NOT NULL, -- 0..6
  start_time            TIME NOT NULL,
  end_time              TIME NOT NULL,
  is_active             BOOLEAN NOT NULL DEFAULT TRUE,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_slot_day CHECK (day_of_week BETWEEN 0 AND 6),
  CONSTRAINT ck_slot_time CHECK (end_time > start_time)
);

CREATE INDEX IF NOT EXISTS ix_availability_slots_calendar_day
  ON availability_slots (calendar_settings_id, day_of_week);

CREATE TABLE IF NOT EXISTS availability_overrides (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  calendar_settings_id  UUID NOT NULL REFERENCES calendar_settings(id) ON DELETE CASCADE,

  date                 DATE NOT NULL,
  override_type         override_type NOT NULL,
  start_time            TIME NULL,
  end_time              TIME NULL,
  reason                TEXT NULL,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_override_calendar_date UNIQUE (calendar_settings_id, date),
  CONSTRAINT ck_override_hours CHECK (
    (override_type = 'unavailable' AND start_time IS NULL AND end_time IS NULL)
    OR
    (override_type = 'custom_hours' AND start_time IS NOT NULL AND end_time IS NOT NULL AND end_time > start_time)
  )
);

CREATE TABLE IF NOT EXISTS appointments (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  conversation_id     UUID NULL REFERENCES conversations(id) ON DELETE SET NULL,
  contact_id          UUID NOT NULL REFERENCES contacts(id) ON DELETE RESTRICT,

  customer_email      CITEXT NOT NULL,
  customer_name       TEXT NULL,
  customer_phone      TEXT NULL,

  scheduled_at        TIMESTAMPTZ NULL, -- set when confirmed
  duration_minutes    INTEGER NOT NULL DEFAULT 30,
  status              appointment_status NOT NULL DEFAULT 'pending',

  google_event_id     TEXT NULL,
  google_meet_link    TEXT NULL,

  booking_token       TEXT NOT NULL UNIQUE,
  notes               TEXT NULL,

  reminder_sent       BOOLEAN NOT NULL DEFAULT FALSE,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  cancelled_at        TIMESTAMPTZ NULL,
  cancellation_reason TEXT NULL,

  CONSTRAINT ck_appt_duration_positive CHECK (duration_minutes > 0)
);

CREATE INDEX IF NOT EXISTS ix_appointments_business_scheduled
  ON appointments (business_id, scheduled_at);

CREATE INDEX IF NOT EXISTS ix_appointments_contact
  ON appointments (contact_id);

CREATE TABLE IF NOT EXISTS appointment_notifications (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  appointment_id     UUID NOT NULL REFERENCES appointments(id) ON DELETE CASCADE,

  recipient_email    CITEXT NOT NULL,
  notification_type  notification_type NOT NULL,
  sent_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  status             notification_status NOT NULL DEFAULT 'sent',
  email_service_id   TEXT NULL
);

CREATE INDEX IF NOT EXISTS ix_appt_notifications_appt_sent
  ON appointment_notifications (appointment_id, sent_at DESC);

CREATE TABLE IF NOT EXISTS booking_page_views (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  token              TEXT NOT NULL, -- booking_token from conversation/appointment
  conversation_id     UUID NULL REFERENCES conversations(id) ON DELETE SET NULL,
  viewed_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_booking   BOOLEAN NOT NULL DEFAULT FALSE,
  ip_address          TEXT NULL
);

CREATE INDEX IF NOT EXISTS ix_booking_views_business_viewed
  ON booking_page_views (business_id, viewed_at DESC);

CREATE INDEX IF NOT EXISTS ix_booking_views_token
  ON booking_page_views (token);

-- =========================
-- 9) AUDIT / EVENTS (stateful + troubleshooting)
-- =========================
CREATE TABLE IF NOT EXISTS business_events (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  actor_user_id UUID NULL REFERENCES app_users(id) ON DELETE SET NULL,

  event_type   TEXT NOT NULL,   -- 'conversation_handoff','agent_assigned','booking_confirmed',...
  payload      JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_business_events_business_created
  ON business_events (business_id, created_at DESC);


-- =========================
-- 11) SHARED FUNCTIONS + TRIGGERS
-- =========================

-- 11.1 updated_at helper
CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- Attach updated_at triggers
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_businesses_updated_at') THEN
    CREATE TRIGGER trg_businesses_updated_at
    BEFORE UPDATE ON businesses
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_memberships_updated_at') THEN
    CREATE TRIGGER trg_memberships_updated_at
    BEFORE UPDATE ON business_memberships
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_subscriptions_updated_at') THEN
    CREATE TRIGGER trg_subscriptions_updated_at
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_business_settings_updated_at') THEN
    CREATE TRIGGER trg_business_settings_updated_at
    BEFORE UPDATE ON business_settings
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_kb_items_updated_at') THEN
    CREATE TRIGGER trg_kb_items_updated_at
    BEFORE UPDATE ON business_kb_items
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_contacts_updated_at') THEN
    CREATE TRIGGER trg_contacts_updated_at
    BEFORE UPDATE ON contacts
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_conversations_updated_at') THEN
    CREATE TRIGGER trg_conversations_updated_at
    BEFORE UPDATE ON conversations
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_email_campaigns_updated_at') THEN
    CREATE TRIGGER trg_email_campaigns_updated_at
    BEFORE UPDATE ON email_campaigns
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_calendar_settings_updated_at') THEN
    CREATE TRIGGER trg_calendar_settings_updated_at
    BEFORE UPDATE ON calendar_settings
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_appointments_updated_at') THEN
    CREATE TRIGGER trg_appointments_updated_at
    BEFORE UPDATE ON appointments
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
  END IF;
END $$;

-- 11.2 Auto-create default business settings + calendar settings on business create
CREATE OR REPLACE FUNCTION trg_businesses_after_insert_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO business_settings (business_id)
  VALUES (NEW.id)
  ON CONFLICT (business_id) DO NOTHING;

  INSERT INTO calendar_settings (business_id)
  VALUES (NEW.id)
  ON CONFLICT (business_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_businesses_defaults') THEN
    CREATE TRIGGER trg_businesses_defaults
    AFTER INSERT ON businesses
    FOR EACH ROW EXECUTE FUNCTION trg_businesses_after_insert_defaults();
  END IF;
END $$;

-- 11.3 Enforce membership seat limits per business (agents only)
-- Rule examples:
--  free:   1 owner + 2 agents
--  pro:    1 owner + 5 agents
--  premium:1 owner + 20 agents
--  enterprise: configured (tier + extra seats or override)
CREATE OR REPLACE FUNCTION trg_membership_enforce_seats()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  tier subscription_tier_code;
  included_agents INTEGER;
  extra_agents INTEGER;
  override_max INTEGER;
  allowed_agents INTEGER;
  current_agents INTEGER;
BEGIN
  -- Only on active agent membership adds/role changes
  IF (TG_OP = 'INSERT') THEN
    IF NEW.is_active IS NOT TRUE OR NEW.role <> 'agent' THEN
      RETURN NEW;
    END IF;
  ELSIF (TG_OP = 'UPDATE') THEN
    IF (NEW.role <> 'agent' OR NEW.is_active IS NOT TRUE) THEN
      RETURN NEW;
    END IF;
    -- If role/is_active unchanged and was already an active agent, allow
    IF (OLD.role = 'agent' AND OLD.is_active IS TRUE AND NEW.role = 'agent' AND NEW.is_active IS TRUE) THEN
      RETURN NEW;
    END IF;
  END IF;

  -- Determine tier from businesses.current_tier (fast path)
  SELECT b.current_tier, b.max_agent_logins_override
    INTO tier, override_max
  FROM businesses b
  WHERE b.id = NEW.business_id
  FOR UPDATE;

  SELECT t.included_agent_seats
    INTO included_agents
  FROM subscription_tiers t
  WHERE t.code = tier;

  -- Subscription add-ons (most recent active subscription)
  SELECT COALESCE(s.extra_agent_seats, 0)
    INTO extra_agents
  FROM subscriptions s
  WHERE s.business_id = NEW.business_id
    AND s.status IN ('trialing','active','past_due')
  ORDER BY s.created_at DESC
  LIMIT 1;

  allowed_agents := COALESCE(included_agents, 0) + COALESCE(extra_agents, 0);

  IF override_max IS NOT NULL THEN
    allowed_agents := override_max;
  END IF;

  SELECT COUNT(*)
    INTO current_agents
  FROM business_memberships m
  WHERE m.business_id = NEW.business_id
    AND m.role = 'agent'
    AND m.is_active = TRUE;

  -- If inserting, current_agents does not include NEW yet.
  IF current_agents + 1 > allowed_agents THEN
    RAISE EXCEPTION 'Agent seat limit exceeded: allowed %, current %, attempted add 1',
      allowed_agents, current_agents
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_membership_seat_limit') THEN
    CREATE TRIGGER trg_membership_seat_limit
    BEFORE INSERT OR UPDATE OF role, is_active ON business_memberships
    FOR EACH ROW EXECUTE FUNCTION trg_membership_enforce_seats();
  END IF;
END $$;

-- 11.4 Credit ledger trigger: atomic balance update + prevent negative balances
CREATE OR REPLACE FUNCTION trg_credit_ledger_apply()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  new_balance BIGINT;
BEGIN
  IF NEW.delta = 0 THEN
    RAISE EXCEPTION 'Credit ledger delta cannot be 0'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Lock business row and update balance atomically
  UPDATE businesses b
    SET credits_balance = b.credits_balance + NEW.delta
  WHERE b.id = NEW.business_id
  RETURNING credits_balance INTO new_balance;

  IF new_balance IS NULL THEN
    RAISE EXCEPTION 'Business % not found for credit update', NEW.business_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF new_balance < 0 THEN
    -- revert the update
    UPDATE businesses b
      SET credits_balance = b.credits_balance - NEW.delta
    WHERE b.id = NEW.business_id;

    RAISE EXCEPTION 'Insufficient credits for business %: attempted delta %, would become %',
      NEW.business_id, NEW.delta, new_balance
      USING ERRCODE = 'insufficient_resources';
  END IF;

  NEW.balance_after := new_balance;
  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_credit_ledger_apply') THEN
    CREATE TRIGGER trg_credit_ledger_apply
    BEFORE INSERT ON credit_ledger
    FOR EACH ROW EXECUTE FUNCTION trg_credit_ledger_apply();
  END IF;
END $$;

-- 11.5 Keep conversations.updated_at fresh when messages are added
CREATE OR REPLACE FUNCTION trg_messages_touch_conversation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE conversations
  SET updated_at = now()
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_messages_touch_conversation') THEN
    CREATE TRIGGER trg_messages_touch_conversation
    AFTER INSERT ON messages
    FOR EACH ROW EXECUTE FUNCTION trg_messages_touch_conversation();
  END IF;
END $$;

-- =========================
-- 12) SEED DEFAULT TIERS (safe upserts)
-- =========================
INSERT INTO subscription_tiers (code, display_name, included_owner_seats, included_agent_seats, monthly_price_cents)
VALUES
  ('free', 'Free', 1, 2, 0),
  ('pro', 'Pro', 1, 5, NULL),
  ('premium', 'Premium', 1, 20, NULL),
  ('enterprise', 'Enterprise', 1, 20, NULL)
ON CONFLICT (code) DO UPDATE
SET display_name = EXCLUDED.display_name,
    included_owner_seats = EXCLUDED.included_owner_seats,
    included_agent_seats = EXCLUDED.included_agent_seats,
    monthly_price_cents = EXCLUDED.monthly_price_cents;

-- =========================
-- DONE
-- =========================