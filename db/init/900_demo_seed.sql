INSERT INTO tenants (slug, name) VALUES ('salon-a', 'Salon A'), ('salon-b', 'Salon B');

INSERT INTO masters (tenant_id, name, bio)
SELECT t.id, m.name, m.bio
FROM tenants t,
     (VALUES ('Olha', 'Hair colourist'), ('Iryna', 'Nail master')) AS m(name, bio)
WHERE t.slug = 'salon-a';

INSERT INTO masters (tenant_id, name, bio)
SELECT id, 'Maria', 'Stylist' FROM tenants WHERE slug = 'salon-b';

INSERT INTO resource_types (tenant_id, name)
SELECT t.id, n FROM tenants t, unnest(ARRAY['chair', 'nail desk']) AS n
WHERE t.slug = 'salon-a';

INSERT INTO resources (tenant_id, type_id, name)
SELECT tenant_id, id, name || ' 1' FROM resource_types;

INSERT INTO services (tenant_id, name, category)
SELECT t.id, s.name, s.category
FROM tenants t,
     (VALUES ('Manicure', 'Nails'), ('Hair colouring', 'Hair')) AS s(name, category)
WHERE t.slug = 'salon-a';

INSERT INTO service_segments (tenant_id, service_id, position, kind, duration_min, resource_type_id)
SELECT s.tenant_id, s.id, seg.pos, seg.kind::segment_kind, seg.minutes, rt.id
FROM services s
JOIN (VALUES
    ('Manicure',       1, 'active',  60, 'nail desk'),
    ('Hair colouring', 1, 'active',  30, 'chair'),
    ('Hair colouring', 2, 'waiting', 40, 'chair'),
    ('Hair colouring', 3, 'active',  30, 'chair')
) AS seg(service, pos, kind, minutes, rtype) ON seg.service = s.name
JOIN resource_types rt ON rt.tenant_id = s.tenant_id AND rt.name = seg.rtype;

INSERT INTO master_services (tenant_id, master_id, service_id, price_minor)
SELECT m.tenant_id, m.id, s.id, p.price
FROM (VALUES ('Olha', 'Hair colouring', 180000), ('Iryna', 'Manicure', 70000))
     AS p(master, service, price)
JOIN masters  m ON m.name = p.master
JOIN services s ON s.tenant_id = m.tenant_id AND s.name = p.service;

-- Ольга: пн-пт, 10-14 і 15-19 (обід о 14:00)
INSERT INTO working_hours (tenant_id, master_id, weekday, start_time, end_time)
SELECT m.tenant_id, m.id, d, h.s::time, h.e::time
FROM masters m
CROSS JOIN generate_series(1, 5) AS d
CROSS JOIN (VALUES ('10:00', '14:00'), ('15:00', '19:00')) AS h(s, e)
WHERE m.name = 'Olha';

-- Ірина: пн-сб, 9-18 без перерви
INSERT INTO working_hours (tenant_id, master_id, weekday, start_time, end_time)
SELECT m.tenant_id, m.id, d, '09:00'::time, '18:00'::time
FROM masters m
CROSS JOIN generate_series(1, 6) AS d
WHERE m.name = 'Iryna';

-- Ірина у відпустці 2-8 листопада 2026
INSERT INTO time_off (tenant_id, master_id, during, reason)
SELECT tenant_id, id,
       tstzrange('2026-11-02 00:00 Europe/Kyiv', '2026-11-09 00:00 Europe/Kyiv'),
       'Vacation'
FROM masters WHERE name = 'Iryna';