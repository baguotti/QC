CREATE TABLE IF NOT EXISTS clips (
  room TEXT NOT NULL,
  clip TEXT NOT NULL,
  version INTEGER NOT NULL,
  data TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (room, clip)
);
