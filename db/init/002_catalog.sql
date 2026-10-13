-- Хелпер: вмикає ізоляцію салонів для таблиці одним викликом.
-- Для кожної нової таблиці з tenant_id ми просто викликатимемо його.
CREATE FUNCTION enable_tenant_rls(tbl regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', tbl);
    -- FORCE: політика діє навіть на власника таблиці
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', tbl);
    EXECUTE format(
        'CREATE POLICY tenant_isolation ON %s
             USING (tenant_id = current_tenant_id())
             WITH CHECK (tenant_id = current_tenant_id())', tbl);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %s TO chair_app', tbl);
END $$;

CREATE TABLE masters (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    name      text NOT NULL,
    bio       text,
    is_active boolean NOT NULL DEFAULT true,
    UNIQUE (tenant_id, id)
);

-- Типи ресурсів: 'chair', 'nail desk', 'cosmetology room'
CREATE TABLE resource_types (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    name      text NOT NULL,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, name)
);

-- Конкретні ресурси: 'chair 1', 'chair 2'
CREATE TABLE resources (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    type_id   uuid NOT NULL,
    name      text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, type_id) REFERENCES resource_types (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE services (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    name      text NOT NULL,
    category  text,
    is_active boolean NOT NULL DEFAULT true,
    UNIQUE (tenant_id, id)
);

-- Послуга = впорядковані сегменти.
-- 'active': майстер зайнятий. 'waiting': майстер вільний, клієнтка чекає
-- (фарба діє), але крісло все одно зайняте.
CREATE TABLE service_segments (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    service_id       uuid NOT NULL,
    position         smallint NOT NULL CHECK (position > 0),
    kind             segment_kind NOT NULL DEFAULT 'active',
    duration_min     integer NOT NULL CHECK (duration_min > 0),
    resource_type_id uuid,   -- NULL = ресурс не потрібен
    UNIQUE (service_id, position),
    FOREIGN KEY (tenant_id, service_id)       REFERENCES services (tenant_id, id)       ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, resource_type_id) REFERENCES resource_types (tenant_id, id) ON DELETE CASCADE
);

-- Хто яку послугу виконує і за яку ціну (джуніор дешевше, топ-майстер дорожче)
CREATE TABLE master_services (
    tenant_id   uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    master_id   uuid NOT NULL,
    service_id  uuid NOT NULL,
    price_minor integer NOT NULL CHECK (price_minor >= 0),   -- у копійках
    PRIMARY KEY (master_id, service_id),
    FOREIGN KEY (tenant_id, master_id)  REFERENCES masters (tenant_id, id)  ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, service_id) REFERENCES services (tenant_id, id) ON DELETE CASCADE
);

-- Вмикаємо ізоляцію салонів на всіх таблицях каталогу
SELECT enable_tenant_rls('masters');
SELECT enable_tenant_rls('resource_types');
SELECT enable_tenant_rls('resources');
SELECT enable_tenant_rls('services');
SELECT enable_tenant_rls('service_segments');
SELECT enable_tenant_rls('master_services');