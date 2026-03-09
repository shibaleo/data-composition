-- ===========================================
-- unit_master
-- ===========================================
INSERT INTO unit_master (_id, name) VALUES
  ('u-pcs',  'pcs'),
  ('u-g',    'g'),
  ('u-kg',   'kg'),
  ('u-kcal', 'kcal');

-- ===========================================
-- track_master
-- ===========================================
INSERT INTO track_master (_id, name, granularity) VALUES
  ('actual', 'actual', 'point');

-- ===========================================
-- owner
-- ===========================================
INSERT INTO owner (_id, cd, name, is_leaf, parent_id) VALUES
  ('o-me', 'me', 'me', true, NULL);

-- ===========================================
-- resource: grocery
-- ===========================================
INSERT INTO resource (_id, cd, name, category, unit_id, is_leaf, parent_id) VALUES
  ('r-grocery',    'grocery',    'grocery',                  'grocery', 'u-pcs', false, NULL),
  ('r-beverage',   'beverage',   'beverage',                'grocery', 'u-pcs', false, 'r-grocery'),
  ('r-monster-rr', 'monster-rr', 'Monster Energy Ruby Red', 'grocery', 'u-pcs', true,  'r-beverage'),
  ('r-monster-pp', 'monster-pp', 'Monster Energy Pipeline Punch', 'grocery', 'u-pcs', true, 'r-beverage');

-- ===========================================
-- resource: nutrition
-- ===========================================
INSERT INTO resource (_id, cd, name, category, unit_id, is_leaf, parent_id) VALUES
  ('r-nutrition', 'nutrition', 'nutrition', 'nutrition', 'u-kcal', false, NULL),
  ('r-energy',    'energy',    'energy',    'nutrition', 'u-kcal', true,  'r-nutrition'),
  ('r-protein',   'protein',   'protein',   'nutrition', 'u-g',    true,  'r-nutrition'),
  ('r-fat',       'fat',       'fat',       'nutrition', 'u-g',    true,  'r-nutrition'),
  ('r-carb',      'carb',      'carb',      'nutrition', 'u-g',    true,  'r-nutrition'),
  ('r-salt-eq',   'salt_eq',   'salt_eq',   'nutrition', 'u-g',    true,  'r-nutrition');

-- ===========================================
-- resource_track
-- ===========================================
INSERT INTO resource_track (_id, resource_id, track_id) VALUES
  ('rt-monster-rr-a', 'r-monster-rr', 'actual'),
  ('rt-monster-pp-a', 'r-monster-pp', 'actual'),
  ('rt-energy-a',     'r-energy',     'actual'),
  ('rt-protein-a',    'r-protein',    'actual'),
  ('rt-fat-a',        'r-fat',        'actual'),
  ('rt-carb-a',       'r-carb',       'actual'),
  ('rt-salt-eq-a',    'r-salt-eq',    'actual');
