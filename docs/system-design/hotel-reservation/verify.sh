#!/usr/bin/env bash
# Applies schema.sql to a throw-away database `hotel_design` in the Compose Postgres
# and checks the claims of README.md: races, idempotency, holds, payments.
# Usage (from the repo root): docker compose up -d postgres && bash docs/system-design/hotel-reservation/verify.sh
# Never touches the `app` or `app_test` databases.
set -euo pipefail
cd "$(dirname "$0")"

DB=hotel_design
PSQL=(docker compose exec -T postgres psql -U app -v ON_ERROR_STOP=1 -qAtX)
fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }
sql() { "${PSQL[@]}" -d "$DB" -c "$1"; }
expect() { # expect "<description>" "<expected>" "<sql>"
  local got
  got=$(sql "$3" 2>&1 || true)
  if [[ "$got" == *"$2"* ]]; then ok "$1"; else bad "$1: expected '$2', got '$got'"; fi
}
expect_eq() { # exact match, for counts and empty results
  local got
  got=$(sql "$3" 2>&1 || true)
  if [[ "$got" == "$2" ]]; then ok "$1"; else bad "$1: expected '$2', got '$got'"; fi
}
count() { echo "WITH u AS ($1 RETURNING 1) SELECT count(*) FROM u"; }
# run N copies of a statement at once inside the container, print one line per session
parallel() { # parallel <n> <sql with $i placeholder>
  docker compose exec -T -e N="$1" -e Q="$2" -e DB="$DB" postgres sh -c '
    rm -rf /tmp/par && mkdir /tmp/par
    i=1; while [ $i -le $N ]; do
      q=$(echo "$Q" | sed "s/\$i/$i/g")
      psql -U app -d "$DB" -qAtX -v ON_ERROR_STOP=1 -c "$q" > /tmp/par/$i 2>&1 &
      i=$((i + 1))
    done
    wait; cat /tmp/par/*'
}

"${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
"${PSQL[@]}" -d "$DB" < schema.sql
echo "schema applied to $DB"

# ---------------------------------------------------------------- fixtures and the app transaction
"${PSQL[@]}" -d "$DB" <<'SQL'
INSERT INTO hotels (id, name, country, city, address, time_zone, currency)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'Ala-Too', 'KG', 'Bishkek', 'Chui 1', 'Asia/Bishkek', 'KGS');
INSERT INTO room_types (id, hotel_id, name, max_guests)
VALUES ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'Standard', 2);
INSERT INTO rooms (hotel_id, room_type_id, number)
SELECT '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', n::text
FROM generate_series(101, 105) n;
INSERT INTO rate_plans (id, hotel_id, room_type_id, name, is_refundable, free_cancel_hours)
VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1',
        '00000000-0000-0000-0000-0000000000b1', 'Free cancellation', true, 24);
INSERT INTO room_type_inventory (hotel_id, room_type_id, stay_date, total_rooms, sellable)
SELECT '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', d, 5, 5
FROM generate_series(date '2027-01-01', date '2027-01-10', interval '1 day') d;
INSERT INTO daily_rates (hotel_id, room_type_id, rate_plan_id, stay_date, price)
SELECT '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1',
       '00000000-0000-0000-0000-0000000000c1', d, 500000
FROM generate_series(date '2027-01-01', date '2027-01-10', interval '1 day') d;
INSERT INTO guests (id, email, full_name)
VALUES ('00000000-0000-0000-0000-0000000000d1', 'guest@example.com', 'Guest');

-- What the booking service does in one READ COMMITTED transaction (README, "Бронь").
-- p_lock = false skips the explicit FOR UPDATE: then only the counter trigger and CHECK protect.
CREATE FUNCTION book(p_key uuid, p_in date, p_out date, p_lock boolean DEFAULT true) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    h uuid := '00000000-0000-0000-0000-0000000000a1';
    t uuid := '00000000-0000-0000-0000-0000000000b1';
    p uuid := '00000000-0000-0000-0000-0000000000c1';
    v_id uuid; r record; n integer := 0;
BEGIN
    -- 1. idempotency first: a concurrent duplicate waits here on the unique index
    INSERT INTO reservations (hotel_id, room_type_id, rate_plan_id, guest_id, idempotency_key, request_hash,
                              check_in, check_out, guests_count, guest_name, hold_expires_at, total_amount, currency)
    VALUES (h, t, p, '00000000-0000-0000-0000-0000000000d1', p_key,
            sha256(convert_to(p_in::text || p_out::text, 'UTF8')), p_in, p_out, 2, 'Guest', now() + interval '15 minutes',
            (SELECT coalesce(sum(price), 1) FROM daily_rates
              WHERE hotel_id = h AND rate_plan_id = p AND stay_date >= p_in AND stay_date < p_out), 'KGS')
    ON CONFLICT (hotel_id, idempotency_key) DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RETURN (SELECT id FROM reservations WHERE hotel_id = h AND idempotency_key = p_key);
    END IF;
    -- 2. lock the nights in one order (by date): overlapping stays queue, never deadlock
    IF p_lock THEN
        FOR r IN SELECT stay_date, reserved, sellable FROM room_type_inventory
                  WHERE hotel_id = h AND room_type_id = t AND stay_date >= p_in AND stay_date < p_out
                  ORDER BY stay_date FOR UPDATE LOOP
            n := n + 1;
            IF r.reserved >= r.sellable THEN
                RAISE EXCEPTION 'SOLD_OUT %', r.stay_date;
            END IF;
        END LOOP;
        IF n <> p_out - p_in THEN
            RAISE EXCEPTION 'NOT_ON_SALE';
        END IF;
    END IF;
    PERFORM pg_sleep(0.02); -- the app's round trips between statements widen the race window
    -- 3. nights: the trigger adds 1 to each counter, CHECK forbids going above sellable
    INSERT INTO reservation_nights (reservation_id, hotel_id, room_type_id, stay_date, price)
    SELECT v_id, h, t, stay_date, price FROM daily_rates
     WHERE hotel_id = h AND rate_plan_id = p AND stay_date >= p_in AND stay_date < p_out
     ORDER BY stay_date;
    INSERT INTO outbox (hotel_id, topic, key, payload)
    VALUES (h, 'reservation.created', 'reservation.created:' || v_id, jsonb_build_object('id', v_id));
    RETURN v_id;
END $$;

-- The naive alternative: count active nights, then insert. No counter row, nothing to lock.
CREATE TABLE naive_nights (id bigserial PRIMARY KEY, stay_date date NOT NULL);
CREATE FUNCTION naive_book(p_in date, p_out date) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM generate_series(p_in, p_out - 1, interval '1 day') d
                WHERE (SELECT count(*) FROM naive_nights WHERE stay_date = d) >= 5) THEN
        RAISE EXCEPTION 'SOLD_OUT';
    END IF;
    PERFORM pg_sleep(0.5); -- wide window: 40 psql sessions start staggered
    INSERT INTO naive_nights (stay_date) SELECT generate_series(p_in, p_out - 1, interval '1 day');
    RETURN 'booked';
END $$;
SQL

# ---------------------------------------------------------------- 1. the last rooms, naive check-then-insert
for iso in "READ COMMITTED" "REPEATABLE READ" "SERIALIZABLE"; do
  sql "TRUNCATE naive_nights" >/dev/null
  out=$(parallel 40 "BEGIN ISOLATION LEVEL $iso; SELECT naive_book('2027-01-02', '2027-01-05'); COMMIT;")
  booked=$(grep -c '^booked' <<<"$out" || true)
  serial=$(grep -c 'could not serialize' <<<"$out" || true)
  max=$(sql "SELECT coalesce(max(c), 0) FROM (SELECT count(*) c FROM naive_nights GROUP BY stay_date) x")
  echo "     naive, $iso: booked $booked of 40 for 5 rooms, max per night $max, serialization failures $serial"
  if [[ "$iso" == "SERIALIZABLE" ]]; then
    ((max <= 5)) && ok "naive + SERIALIZABLE does not oversell" || bad "naive + SERIALIZABLE oversold: $max"
  else
    ((max > 5)) && ok "naive + $iso oversells (expected anomaly)" || bad "naive + $iso did not reproduce the race"
  fi
done

# ---------------------------------------------------------------- 2. our transaction: counter + FOR UPDATE
check_inventory() { # $1 = label
  local max drift
  max=$(sql "SELECT max(reserved) FROM room_type_inventory")
  drift=$(sql "SELECT count(*) FROM room_type_inventory i WHERE reserved <> (
      SELECT count(*) FROM reservation_nights n JOIN reservations r ON r.id = n.reservation_id
       WHERE n.stay_date = i.stay_date AND r.status IN ('pending', 'confirmed', 'checked_in'))")
  local full
  full=$(sql "SELECT string_agg(reserved::text, ',' ORDER BY stay_date) FROM room_type_inventory
               WHERE stay_date IN ('2027-01-02', '2027-01-04')")
  ((max <= 5)) && ok "$1: max reserved per night $max <= 5" || bad "$1: oversold, max $max"
  [[ "$full" == "5,5" ]] && ok "$1: contested nights 01-02 and 01-04 sold exactly to 5" \
    || bad "$1: contested nights not filled: $full"
  ((drift == 0)) && ok "$1: counter equals active nights on every date" || bad "$1: counter drift on $drift dates"
}
# overlapping stays in three shapes, so that lock order matters
q="SELECT book(gen_random_uuid(), (ARRAY[date '2027-01-02', date '2027-01-01', date '2027-01-04'])[\$i % 3 + 1], (ARRAY[date '2027-01-05', date '2027-01-03', date '2027-01-07'])[\$i % 3 + 1], LOCK);"
out=$(parallel 40 "${q//LOCK/true}")
echo "     FOR UPDATE: $(grep -cE '^[0-9a-f]{8}-' <<<"$out" || true) booked, $(grep -c 'SOLD_OUT' <<<"$out" || true) SOLD_OUT, $(grep -c 'deadlock' <<<"$out" || true) deadlocks, $(grep -c 'inventory_not_oversold' <<<"$out" || true) CHECK violations"
grep -q deadlock <<<"$out" && bad "deadlock with ordered locks" || ok "no deadlocks with locks ordered by date"
grep -q inventory_not_oversold <<<"$out" && bad "CHECK fired: explicit lock let a booking through" || ok "explicit lock answers SOLD_OUT before the CHECK is needed"
check_inventory "FOR UPDATE"

# same again without the explicit lock: only the trigger's UPDATE and the CHECK stand in the way
sql "UPDATE reservations SET status = 'cancelled' WHERE status = 'pending'" >/dev/null
out=$(parallel 40 "${q//LOCK/false}")
echo "     no FOR UPDATE: $(grep -cE '^[0-9a-f]{8}-' <<<"$out" || true) booked, $(grep -c 'inventory_not_oversold' <<<"$out" || true) CHECK violations, $(grep -c 'deadlock' <<<"$out" || true) deadlocks"
check_inventory "trigger + CHECK only"
sql "UPDATE reservations SET status = 'cancelled' WHERE status = 'pending'" >/dev/null

# ---------------------------------------------------------------- 3. idempotency of POST /reservations
key=$(sql "SELECT gen_random_uuid()")
out=$(parallel 10 "SELECT book('$key', '2027-01-08', '2027-01-10');")
distinct=$( (grep -E '^[0-9a-f]{8}-' <<<"$out" || true) | sort -u | wc -l)
rows=$(sql "SELECT count(*) FROM reservations WHERE idempotency_key = '$key'")
((distinct == 1 && rows == 1)) && ok "10 concurrent retries with one key: 1 reservation, same id to all" \
  || bad "idempotency: $rows rows, $distinct distinct ids"
expect_eq "inventory taken once for the retried booking" "1" \
  "SELECT reserved FROM room_type_inventory WHERE stay_date = '2027-01-08'"

# ---------------------------------------------------------------- 4. hold expiry vs late confirmation
res=$(sql "SELECT id FROM reservations WHERE idempotency_key = '$key'")
sql "UPDATE reservations SET hold_expires_at = now() - interval '1 second' WHERE id = '$res'" >/dev/null
sweep="WITH due AS (SELECT id FROM reservations WHERE status = 'pending' AND hold_expires_at < now()
        ORDER BY hold_expires_at LIMIT 500 FOR UPDATE SKIP LOCKED)
      UPDATE reservations r SET status = 'expired' FROM due WHERE r.id = due.id RETURNING r.id"
expect "sweeper expires the hold" "$res" "$sweep"
expect_eq "inventory released by the status trigger" "0" \
  "SELECT reserved FROM room_type_inventory WHERE stay_date = '2027-01-08'"
expect_eq "second sweep finds nothing (released once)" "" "$sweep"
expect_eq "late payment cannot confirm an expired hold (0 rows -> void the authorization)" "0" \
  "$(count "UPDATE reservations SET status = 'confirmed' WHERE id = '$res' AND status = 'pending'")"
expect "forbidden transition expired -> confirmed" "reservation status expired -> confirmed is not allowed" \
  "UPDATE reservations SET status = 'confirmed' WHERE id = '$res'"

# ---------------------------------------------------------------- 5. one physical room, two guests
a=$(sql "SELECT book(gen_random_uuid(), '2027-01-08', '2027-01-10')")
expect "booking a night that is not on sale fails (01-11 has no inventory row)" "NOT_ON_SALE" \
  "SELECT book(gen_random_uuid(), '2027-01-10', '2027-01-12')"
b=$(sql "SELECT book(gen_random_uuid(), '2027-01-09', '2027-01-10')")
room=$(sql "SELECT id FROM rooms WHERE number = '101'")
assign="INSERT INTO room_assignments (reservation_id, hotel_id, room_id, check_in, check_out)
        SELECT id, hotel_id, '$room', check_in, check_out FROM reservations WHERE id ="
sql "$assign '$a'" >/dev/null && ok "room 101 assigned to the first stay" || bad "first assignment failed"
expect "room 101 cannot be given to an overlapping stay" "room_not_double_assigned" "$assign '$b'"

# ---------------------------------------------------------------- 6. payments
pay="INSERT INTO payments (hotel_id, reservation_id, idempotency_key, amount, currency, provider)
     SELECT hotel_id, id, gen_random_uuid(), total_amount, currency, 'psp' FROM reservations WHERE id = '$a' RETURNING id"
p1=$(sql "$pay")
expect "second live payment for the same reservation (two tabs)" "payments_one_live_per_reservation" "$pay"
auth="UPDATE payments SET status = 'authorized', provider_payment_id = 'pi_1' WHERE id = '$p1' AND status = 'created'"
expect_eq "first 'authorized' response moves the payment" "1" "$(count "$auth")"
expect_eq "repeated 'authorized' (retry, duplicate webhook) is a no-op" "0" "$(count "$auth")"
sql "UPDATE payments SET status = 'captured' WHERE id = '$p1' AND status = 'authorized'" >/dev/null
expect "captured payment cannot go back to authorized" "payment status captured -> authorized is not allowed" \
  "UPDATE payments SET status = 'authorized' WHERE id = '$p1'"
hook="INSERT INTO psp_webhook_events (provider, event_id, payment_id, type, payload)
      VALUES ('psp', 'evt_1', '$p1', 'payment.captured', '{}') ON CONFLICT DO NOTHING RETURNING event_id"
expect "first webhook delivery is taken" "evt_1" "$hook"
expect_eq "duplicate webhook delivery is skipped" "" "$hook"
refund="INSERT INTO refunds (hotel_id, payment_id, payment_amount, amount, reason)
        SELECT hotel_id, id, amount, AMOUNT, 'cancel' FROM payments WHERE id = '$p1'"
expect "refund above the payment is rejected" "refunds_amount" "${refund//AMOUNT/amount + 1}"
sql "${refund//AMOUNT/amount - 100000}" >/dev/null && ok "refund minus cancellation fee accepted" || bad "refund rejected"
expect "second live refund for the same payment" "refunds_one_live_per_payment" "${refund//AMOUNT/100}"

# ---------------------------------------------------------------- 7. deferred check at COMMIT
expect "reservation whose total does not match its nights is rejected at COMMIT" "nights do not match its dates or total" \
  "INSERT INTO reservations (hotel_id, room_type_id, rate_plan_id, guest_id, idempotency_key, request_hash,
     check_in, check_out, guests_count, guest_name, hold_expires_at, total_amount, currency)
   SELECT hotel_id, room_type_id, rate_plan_id, guest_id, gen_random_uuid(), request_hash,
     check_in, check_out, 1, 'X', now(), 1, currency FROM reservations WHERE id = '$a'"

"${PSQL[@]}" -d postgres -c "DROP DATABASE $DB"
((fail == 0)) && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
