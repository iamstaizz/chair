-- Роль для застосунку: НЕ суперюзер і не може обходити RLS.
-- Суперюзери ігнорують row-level security повністю, тому
-- застосунок підключатиметься тільки під цією роллю.
CREATE ROLE chair_app LOGIN PASSWORD 'chair_app' NOSUPERUSER NOBYPASSRLS;