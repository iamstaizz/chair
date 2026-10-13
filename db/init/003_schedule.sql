-- Робочі години. Час "настінний" (як на годиннику салону), у часовому поясі салону.
-- Кілька рядків на день = перерви.
CREATE TABLE working_hours (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    master_id  uuid NOT NULL,
    weekday    smallint NOT NULL CHECK (weekday BETWEEN 1 AND 7),   -- ISO: 1 = понеділок
    start_time time NOT NULL,
    end_time   time NOT NULL,
    CHECK (end_time > start_time),
    FOREIGN KEY (tenant_id, master_id) REFERENCES masters (tenant_id, id) ON DELETE CASCADE,

    -- Зміни одного майстра в один день не можуть перетинатися.
    -- Час переводимо в хвилини від півночі, щоб скористатись діапазонами.
    EXCLUDE USING gist (
        master_id WITH =,
        weekday   WITH =,
        int4range(
            (extract(epoch FROM start_time) / 60)::int,
            (extract(epoch FROM end_time)   / 60)::int
        ) WITH &&
    )
);

-- Відпустки, лікарняні, винятки на конкретні дати
CREATE TABLE time_off (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    master_id uuid NOT NULL,
    during    tstzrange NOT NULL,   -- конкретний проміжок часу, з часовим поясом
    reason    text,
    CHECK (NOT isempty(during)),
    FOREIGN KEY (tenant_id, master_id) REFERENCES masters (tenant_id, id) ON DELETE CASCADE,
    EXCLUDE USING gist (master_id WITH =, during WITH &&)
);

SELECT enable_tenant_rls('working_hours');
SELECT enable_tenant_rls('time_off');