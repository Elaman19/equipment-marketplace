-- Hotel reservation database: design for task 08, week 1.
-- Not used by the marketplace app. Applied and exercised by verify.sh on PostgreSQL 17.
--
-- Rules that the database itself guarantees:
--   1. A room type is never sold above `sellable` for any night (CHECK on the counter,
--      the counter is changed only by triggers on reservation_nights / reservations).
--   2. One physical room is never assigned to two overlapping stays (EXCLUDE).
--   3. A retried booking request creates no second reservation (UNIQUE idempotency key).
--   4. A reservation has at most one live payment; a payment at most one live refund,
--      never larger than the payment (partial UNIQUE, composite FK + CHECK).
--   5. A PSP webhook is processed once (PRIMARY KEY on the provider event id).
--   6. Statuses move only along allowed transitions (triggers).
--
-- Every booking-side key starts with hotel_id: all rows of one hotel can later live
-- on one shard, and every constraint stays local to that shard.

CREATE EXTENSION IF NOT EXISTS btree_gist; -- uuid "=" inside a GiST exclusion constraint

-- ---------------------------------------------------------------- catalog

CREATE TABLE hotels (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text NOT NULL,
    country    char(2) NOT NULL,
    city       text NOT NULL,
    address    text NOT NULL,
    time_zone  text NOT NULL,           -- IANA name; a night (stay_date) is a local calendar date
    currency   char(3) NOT NULL,        -- prices of this hotel are in this currency
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE room_types (
    id         uuid NOT NULL DEFAULT gen_random_uuid(),
    hotel_id   uuid NOT NULL REFERENCES hotels (id),
    name       text NOT NULL,
    max_guests smallint NOT NULL CHECK (max_guests > 0),
    PRIMARY KEY (id),
    CONSTRAINT room_types_hotel_id_key UNIQUE (hotel_id, id),  -- target of composite FKs
    CONSTRAINT room_types_name_key UNIQUE (hotel_id, name)
);

CREATE TABLE rooms (
    id           uuid NOT NULL DEFAULT gen_random_uuid(),
    hotel_id     uuid NOT NULL,
    room_type_id uuid NOT NULL,
    number       text NOT NULL,
    is_active    boolean NOT NULL DEFAULT true,
    PRIMARY KEY (id),
    CONSTRAINT rooms_hotel_id_key UNIQUE (hotel_id, id),
    CONSTRAINT rooms_number_key UNIQUE (hotel_id, number),
    FOREIGN KEY (hotel_id, room_type_id) REFERENCES room_types (hotel_id, id)
);

CREATE TABLE rate_plans (
    id                uuid NOT NULL DEFAULT gen_random_uuid(),
    hotel_id          uuid NOT NULL,
    room_type_id      uuid NOT NULL,
    name              text NOT NULL,     -- "free cancellation", "non-refundable", ...
    is_refundable     boolean NOT NULL,
    free_cancel_hours integer CHECK (free_cancel_hours >= 0), -- before check-in; NULL = never free
    PRIMARY KEY (id),
    CONSTRAINT rate_plans_hotel_id_key UNIQUE (hotel_id, room_type_id, id),
    FOREIGN KEY (hotel_id, room_type_id) REFERENCES room_types (hotel_id, id)
);

-- ---------------------------------------------------------------- inventory and prices

-- One row per room type and night. This is the row concurrent bookings contend on.
CREATE TABLE room_type_inventory (
    hotel_id     uuid NOT NULL,
    room_type_id uuid NOT NULL,
    stay_date    date NOT NULL,
    total_rooms  integer NOT NULL CHECK (total_rooms >= 0),
    sellable     integer NOT NULL,             -- total_rooms + overbooking; 0 = stop sale
    reserved     integer NOT NULL DEFAULT 0,   -- changed only by triggers below
    PRIMARY KEY (hotel_id, room_type_id, stay_date),
    FOREIGN KEY (hotel_id, room_type_id) REFERENCES room_types (hotel_id, id),
    CONSTRAINT inventory_overbooking_limit CHECK (sellable >= 0 AND sellable * 10 <= total_rooms * 11),
    CONSTRAINT inventory_not_oversold CHECK (reserved >= 0 AND reserved <= sellable)
);

CREATE TABLE daily_rates (
    hotel_id     uuid NOT NULL,
    room_type_id uuid NOT NULL,
    rate_plan_id uuid NOT NULL,
    stay_date    date NOT NULL,
    price        bigint NOT NULL CHECK (price > 0),   -- minor units of hotels.currency
    PRIMARY KEY (hotel_id, rate_plan_id, stay_date),
    FOREIGN KEY (hotel_id, room_type_id, rate_plan_id) REFERENCES rate_plans (hotel_id, room_type_id, id)
);

-- ---------------------------------------------------------------- booking

CREATE TABLE guests (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email      text NOT NULL,
    full_name  text NOT NULL,
    phone      text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX guests_email_key ON guests (lower(email));

CREATE TYPE reservation_status AS ENUM
    ('pending', 'confirmed', 'cancelled', 'expired', 'checked_in', 'checked_out', 'no_show');

CREATE TABLE reservations (
    id              uuid NOT NULL DEFAULT gen_random_uuid(),
    hotel_id        uuid NOT NULL,
    room_type_id    uuid NOT NULL,
    rate_plan_id    uuid NOT NULL,
    guest_id        uuid NOT NULL REFERENCES guests (id),  -- cross-shard after sharding: dropped then
    idempotency_key uuid NOT NULL,          -- Idempotency-Key header of POST /reservations
    request_hash    bytea NOT NULL,         -- same key + other body = 422, not a silent replay
    check_in        date NOT NULL,
    check_out       date NOT NULL,
    guests_count    smallint NOT NULL CHECK (guests_count > 0),
    guest_name      text NOT NULL,          -- who stays; may differ from the account owner
    status          reservation_status NOT NULL DEFAULT 'pending',
    hold_expires_at timestamptz NOT NULL,   -- pending hold is released after this moment
    total_amount    bigint NOT NULL CHECK (total_amount > 0),
    currency        char(3) NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    CONSTRAINT reservations_hotel_id_key UNIQUE (hotel_id, id),
    CONSTRAINT reservations_room_type_key UNIQUE (hotel_id, id, room_type_id),
    CONSTRAINT reservations_stay_key UNIQUE (hotel_id, id, check_in, check_out),
    CONSTRAINT reservations_idempotency_key UNIQUE (hotel_id, idempotency_key),
    CONSTRAINT reservations_dates CHECK (check_out > check_in AND check_out - check_in <= 30),
    FOREIGN KEY (hotel_id, room_type_id, rate_plan_id) REFERENCES rate_plans (hotel_id, room_type_id, id)
);
CREATE INDEX reservations_pending_hold ON reservations (hold_expires_at) WHERE status = 'pending';
CREATE INDEX reservations_guest ON reservations (guest_id, check_in DESC);

-- One row per night: price fixed at booking time, and the exact set of inventory rows to release.
CREATE TABLE reservation_nights (
    reservation_id uuid NOT NULL,
    hotel_id       uuid NOT NULL,
    room_type_id   uuid NOT NULL,
    stay_date      date NOT NULL,
    price          bigint NOT NULL CHECK (price > 0),
    PRIMARY KEY (reservation_id, stay_date),
    FOREIGN KEY (hotel_id, reservation_id, room_type_id)
        REFERENCES reservations (hotel_id, id, room_type_id),
    FOREIGN KEY (hotel_id, room_type_id, stay_date)
        REFERENCES room_type_inventory (hotel_id, room_type_id, stay_date)
);

-- Physical room, usually chosen by the hotel close to check-in (upgrade to another type is allowed).
CREATE TABLE room_assignments (
    reservation_id uuid NOT NULL,
    hotel_id       uuid NOT NULL,
    room_id        uuid NOT NULL,
    check_in       date NOT NULL,
    check_out      date NOT NULL,
    PRIMARY KEY (reservation_id),
    FOREIGN KEY (hotel_id, reservation_id, check_in, check_out)
        REFERENCES reservations (hotel_id, id, check_in, check_out),
    FOREIGN KEY (hotel_id, room_id) REFERENCES rooms (hotel_id, id),
    CONSTRAINT room_not_double_assigned
        EXCLUDE USING gist (room_id WITH =, daterange(check_in, check_out) WITH &&)
);

-- ---------------------------------------------------------------- payments

CREATE TYPE payment_status AS ENUM ('created', 'authorized', 'captured', 'failed', 'voided');

CREATE TABLE payments (
    id                  uuid NOT NULL DEFAULT gen_random_uuid(), -- sent to the PSP as Idempotency-Key
    hotel_id            uuid NOT NULL,
    reservation_id      uuid NOT NULL,
    idempotency_key     uuid NOT NULL,      -- Idempotency-Key header of POST /reservations/:id/payments
    amount              bigint NOT NULL CHECK (amount > 0),
    currency            char(3) NOT NULL,
    status              payment_status NOT NULL DEFAULT 'created',
    provider            text NOT NULL,
    provider_payment_id text,               -- known after the PSP answered once
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    CONSTRAINT payments_amount_key UNIQUE (id, amount),   -- target of refunds FK
    CONSTRAINT payments_idempotency_key UNIQUE (hotel_id, idempotency_key),
    CONSTRAINT payments_provider_id_key UNIQUE (provider, provider_payment_id),
    FOREIGN KEY (hotel_id, reservation_id) REFERENCES reservations (hotel_id, id)
);
-- Two tabs, two keys, one reservation: still one live payment.
CREATE UNIQUE INDEX payments_one_live_per_reservation ON payments (reservation_id)
    WHERE status IN ('created', 'authorized', 'captured');
CREATE INDEX payments_stuck ON payments (created_at) WHERE status = 'created';

CREATE TYPE refund_status AS ENUM ('created', 'succeeded', 'failed');

CREATE TABLE refunds (
    id                 uuid NOT NULL DEFAULT gen_random_uuid(),  -- Idempotency-Key to the PSP
    hotel_id           uuid NOT NULL,
    payment_id         uuid NOT NULL,
    payment_amount     bigint NOT NULL,
    amount             bigint NOT NULL,
    status             refund_status NOT NULL DEFAULT 'created',
    provider_refund_id text UNIQUE,
    reason             text NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    FOREIGN KEY (payment_id, payment_amount) REFERENCES payments (id, amount),
    CONSTRAINT refunds_amount CHECK (amount > 0 AND amount <= payment_amount)
);
CREATE UNIQUE INDEX refunds_one_live_per_payment ON refunds (payment_id) WHERE status <> 'failed';

-- Inbox of PSP webhooks: delivery is at-least-once, processing is once.
CREATE TABLE psp_webhook_events (
    provider     text NOT NULL,
    event_id     text NOT NULL,
    payment_id   uuid,               -- from event metadata; NULL if the PSP event is not ours
    type         text NOT NULL,
    payload      jsonb NOT NULL,
    received_at  timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,
    PRIMARY KEY (provider, event_id)
);

-- Transactional outbox: capture/void jobs, e-mails, events for search and cache.
CREATE TABLE outbox (
    id           bigserial PRIMARY KEY,
    hotel_id     uuid NOT NULL,
    topic        text NOT NULL,
    key          text NOT NULL,     -- deterministic job id: dedupe in the queue
    payload      jsonb NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
);
CREATE INDEX outbox_unpublished ON outbox (id) WHERE published_at IS NULL;

-- ---------------------------------------------------------------- triggers

-- A night can be added only to a pending reservation, and it takes one unit of inventory.
-- The UPDATE row-locks the counter, so concurrent bookings of the same night queue here,
-- and inventory_not_oversold is checked against the latest committed value.
CREATE FUNCTION reservation_night_take() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT status FROM reservations WHERE id = NEW.reservation_id) <> 'pending' THEN
        RAISE EXCEPTION 'nights can be added only to a pending reservation'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'reservation_nights_pending_only';
    END IF;
    UPDATE room_type_inventory SET reserved = reserved + 1
     WHERE hotel_id = NEW.hotel_id AND room_type_id = NEW.room_type_id AND stay_date = NEW.stay_date;
    RETURN NEW;
END $$;
CREATE TRIGGER reservation_nights_take AFTER INSERT ON reservation_nights
    FOR EACH ROW EXECUTE FUNCTION reservation_night_take();

CREATE FUNCTION forbid_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = 'check_violation';
END $$;
CREATE TRIGGER reservation_nights_append_only BEFORE UPDATE OR DELETE ON reservation_nights
    FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- At COMMIT: the nights cover exactly [check_in, check_out) and add up to total_amount.
CREATE FUNCTION reservation_nights_match() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n integer; lo date; hi date; s bigint;
BEGIN
    SELECT count(*), min(stay_date), max(stay_date), sum(price) INTO n, lo, hi, s
      FROM reservation_nights WHERE reservation_id = NEW.id;
    IF n <> NEW.check_out - NEW.check_in OR lo <> NEW.check_in OR hi <> NEW.check_out - 1
       OR s <> NEW.total_amount THEN
        RAISE EXCEPTION 'reservation % nights do not match its dates or total', NEW.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'reservation_nights_match';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER reservations_nights_match AFTER INSERT ON reservations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reservation_nights_match();

-- Allowed status transitions; leaving an active status releases the inventory exactly once.
CREATE FUNCTION reservation_status_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;
    IF NOT (OLD.status, NEW.status) IN (
        ('pending', 'confirmed'), ('pending', 'expired'), ('pending', 'cancelled'),
        ('confirmed', 'cancelled'), ('confirmed', 'checked_in'), ('confirmed', 'no_show'),
        ('checked_in', 'checked_out')) THEN
        RAISE EXCEPTION 'reservation status % -> % is not allowed', OLD.status, NEW.status
            USING ERRCODE = 'check_violation', CONSTRAINT = 'reservation_status_transition';
    END IF;
    IF NEW.status IN ('cancelled', 'expired') THEN
        -- same lock order as booking (by night), otherwise booking vs cancel can deadlock
        PERFORM 1 FROM room_type_inventory
         WHERE hotel_id = NEW.hotel_id AND room_type_id = NEW.room_type_id
           AND stay_date >= NEW.check_in AND stay_date < NEW.check_out
         ORDER BY stay_date FOR UPDATE;
        UPDATE room_type_inventory i SET reserved = i.reserved - 1
          FROM reservation_nights n
         WHERE n.reservation_id = NEW.id
           AND i.hotel_id = n.hotel_id AND i.room_type_id = n.room_type_id AND i.stay_date = n.stay_date;
        DELETE FROM room_assignments WHERE reservation_id = NEW.id;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END $$;
CREATE TRIGGER reservations_status_change BEFORE UPDATE OF status ON reservations
    FOR EACH ROW EXECUTE FUNCTION reservation_status_change();

CREATE FUNCTION payment_status_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;
    IF NOT (OLD.status, NEW.status) IN (
        ('created', 'authorized'), ('created', 'failed'),
        ('authorized', 'captured'), ('authorized', 'voided'), ('authorized', 'failed')) THEN
        RAISE EXCEPTION 'payment status % -> % is not allowed', OLD.status, NEW.status
            USING ERRCODE = 'check_violation', CONSTRAINT = 'payment_status_transition';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END $$;
CREATE TRIGGER payments_status_change BEFORE UPDATE OF status ON payments
    FOR EACH ROW EXECUTE FUNCTION payment_status_change();
