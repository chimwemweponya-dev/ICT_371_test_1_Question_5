-- Q5(a) Tables & Seed Data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_allocation_dates CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

-- Q5(b) Function: fn_free_beds
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cap      INTEGER;
    v_occupied INTEGER;
BEGIN
    SELECT capacity INTO v_cap
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_cap - COALESCE(v_occupied, 0);
END;
$$;

-- Q5(d) Trigger: BEFORE INSERT OR UPDATE capacity & single ACTIVE allocation
CREATE OR REPLACE FUNCTION fn_trg_allocations_validate()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cap          INTEGER;
    v_other_active INTEGER;
    v_student_act  INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_cap
        FROM rooms
        WHERE room_id = NEW.room_id;

        SELECT COUNT(*) INTO v_other_active
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_other_active >= v_cap THEN
            RAISE EXCEPTION 'Room % has reached capacity (%)', NEW.room_id, v_cap;
        END IF;

        SELECT COUNT(*) INTO v_student_act
        FROM allocations
        WHERE student_id = NEW.student_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_student_act > 0 THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE room allocation', NEW.student_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_validate
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_trg_allocations_validate();

-- Q5(c) Procedure: pr_allocate_room
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INT,
    p_room_id      INT,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'No free beds available in room %', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- Seed rooms (full=A101 [2/2], partly=B102 [1/2], empty=C103 [0/2]), students & allocations
INSERT INTO rooms (room_number, capacity) VALUES ('A101', 2), ('B102', 2), ('C103', 2);
INSERT INTO students (student_number, full_name) VALUES
    ('S101', 'Chileshe Mwape'),
    ('S102', 'Kabwe Mulenga'),
    ('S103', 'Nanyangwe Sichone'),
    ('S104', 'Musonda Kapansa');

CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 25);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 60, CURRENT_DATE - 10, 'ENDED');

-- Q5(e) View: all rooms with capacity, occupied_beds, free_beds
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity
ORDER BY r.room_number;

-- Q5(f) Partial Index & EXPLAIN
-- Targets ACTIVE allocations by room_id without indexing ENDED history
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
-- Expected plan node: Index Scan using idx_allocations_active_room on allocations

-- Q5(g) Procedure & Scheduled Job (23:55 daily for CURRENT_DATE)
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
DECLARE
    v_today DATE := CURRENT_DATE;
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT
        v_today,
        r.room_id,
        COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE'),
        r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule(
    'refresh_hostel_occupancy',
    '55 23 * * *',
    $$CALL pr_refresh_occupancy();$$
);