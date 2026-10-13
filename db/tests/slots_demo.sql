-- Manual demo of double-booking protection. Safe to run many times.
-- Run: docker compose exec db psql -U chair -d chair -f /tests/slots_demo.sql

-- 0. Clean up previous runs (bookings first: their segments are deleted with them)
DELETE FROM bookings WHERE client_id IN (SELECT id FROM clients WHERE phone = '+380500000001');
DELETE FROM clients WHERE phone = '+380500000001';

-- 1. Remember ids in psql variables
SELECT id AS tid FROM tenants WHERE slug = 'salon-a' \gset
SELECT id AS olha FROM masters WHERE name = 'Olha' \gset
SELECT id AS iryna FROM masters WHERE name = 'Iryna' \gset
SELECT id AS svc_color FROM services WHERE name = 'Hair colouring' \gset
SELECT id AS svc_mani FROM services WHERE name = 'Manicure' \gset
SELECT id AS chair FROM resources WHERE name = 'chair 1' \gset
SELECT id AS desk FROM resources WHERE name = 'nail desk 1' \gset

INSERT INTO clients (tenant_id, name, phone) VALUES (:'tid', 'Test Client', '+380500000001') RETURNING id AS client \gset
INSERT INTO bookings (tenant_id, client_id, hold_expires_at, total_minor) VALUES (:'tid', :'client', now() + interval '10 minutes', 180000) RETURNING id AS b1 \gset
INSERT INTO bookings (tenant_id, client_id, hold_expires_at, total_minor) VALUES (:'tid', :'client', now() + interval '10 minutes', 70000) RETURNING id AS b2 \gset

\echo
\echo '=== TEST 1: hair colouring for Olha 10:00-11:40 (expect INSERT 0 3)'
INSERT INTO booking_segments (tenant_id, booking_id, service_id, master_id, resource_id, kind, during) VALUES
 (:'tid', :'b1', :'svc_color', :'olha', :'chair', 'active',  tstzrange('2026-11-16 10:00 Europe/Kyiv', '2026-11-16 10:30 Europe/Kyiv')),
 (:'tid', :'b1', :'svc_color', :'olha', :'chair', 'waiting', tstzrange('2026-11-16 10:30 Europe/Kyiv', '2026-11-16 11:10 Europe/Kyiv')),
 (:'tid', :'b1', :'svc_color', :'olha', :'chair', 'active',  tstzrange('2026-11-16 11:10 Europe/Kyiv', '2026-11-16 11:40 Europe/Kyiv'));

\echo
\echo '=== TEST 2: manicure for Olha 10:30-11:00, while the dye develops (expect INSERT 0 1)'
INSERT INTO booking_segments (tenant_id, booking_id, service_id, master_id, resource_id, kind, during) VALUES
 (:'tid', :'b2', :'svc_mani', :'olha', :'desk', 'active', tstzrange('2026-11-16 10:30 Europe/Kyiv', '2026-11-16 11:00 Europe/Kyiv'));

\echo
\echo '=== TEST 3: Olha is busy 10:10-10:40 (expect ERROR no_master_overlap)'
INSERT INTO booking_segments (tenant_id, booking_id, service_id, master_id, resource_id, kind, during) VALUES
 (:'tid', :'b2', :'svc_mani', :'olha', :'desk', 'active', tstzrange('2026-11-16 10:10 Europe/Kyiv', '2026-11-16 10:40 Europe/Kyiv'));

\echo
\echo '=== TEST 4: Iryna is free but the chair is taken (expect ERROR no_resource_overlap)'
INSERT INTO booking_segments (tenant_id, booking_id, service_id, master_id, resource_id, kind, during) VALUES
 (:'tid', :'b2', :'svc_color', :'iryna', :'chair', 'active', tstzrange('2026-11-16 10:40 Europe/Kyiv', '2026-11-16 11:00 Europe/Kyiv'));

\echo
\echo '=== TEST 5: cancel the colouring, then retry test 4 (expect UPDATE 1, then INSERT 0 1)'
UPDATE bookings SET status = 'cancelled' WHERE id = :'b1';
INSERT INTO booking_segments (tenant_id, booking_id, service_id, master_id, resource_id, kind, during) VALUES
 (:'tid', :'b2', :'svc_color', :'iryna', :'chair', 'active', tstzrange('2026-11-16 10:40 Europe/Kyiv', '2026-11-16 11:00 Europe/Kyiv'));

\echo
\echo '=== LEDGER (occupies = f means the slot was released by cancellation)'
SELECT m.name, s.kind, s.occupies,
       (lower(s.during) AT TIME ZONE 'Europe/Kyiv')::time AS starts,
       (upper(s.during) AT TIME ZONE 'Europe/Kyiv')::time AS ends
FROM booking_segments s JOIN masters m ON m.id = s.master_id
ORDER BY starts, name;