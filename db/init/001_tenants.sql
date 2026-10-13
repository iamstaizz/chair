-- Потрібне розширення для кроку 1.6 (захист від подвійного запису)
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Статуси бронювання та тип сегмента послуги
CREATE TYPE booking_status AS ENUM ('held', 'confirmed', 'completed', 'cancelled', 'no_show');
CREATE TYPE segment_kind   AS ENUM ('active', 'waiting');

-- Поточний салон береться зі змінної сесії app.tenant_id.
-- Якщо її не виставили, повертається NULL, і жоден рядок не проходить
-- політику безпеки (система "закрита за замовчуванням").
CREATE FUNCTION current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid $$;

-- Салони. Тут RLS не потрібен: салон шукається за піддоменом
-- ще до того, як відомо, чиї дані показувати.
CREATE TABLE tenants (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug       text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$'),
    name       text NOT NULL,
    timezone   text NOT NULL DEFAULT 'Europe/Kyiv',
    theme      jsonb NOT NULL DEFAULT '{}',   -- кольори, шрифти, логотип салону
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Застосунок може тільки читати салони
GRANT USAGE ON SCHEMA public TO chair_app;
GRANT SELECT ON tenants TO chair_app;