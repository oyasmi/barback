import Foundation

/// Schema DDL, mirroring design.md §5.2 verbatim. `PRAGMA user_version` drives migrations.
enum Schema {
    static let currentVersion: Int32 = 2

    static let v1 = """
    CREATE TABLE IF NOT EXISTS program (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      kind TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      command TEXT NOT NULL,
      use_shell INTEGER NOT NULL DEFAULT 0,
      directory TEXT,
      env_json TEXT NOT NULL DEFAULT '{}',
      group_name TEXT,
      priority INTEGER NOT NULL DEFAULT 100,
      notes TEXT,
      autostart INTEGER NOT NULL DEFAULT 1,
      autorestart TEXT NOT NULL DEFAULT 'unexpected',
      exit_codes TEXT NOT NULL DEFAULT '[0]',
      start_seconds INTEGER NOT NULL DEFAULT 5,
      start_retries INTEGER NOT NULL DEFAULT 3,
      backoff_base REAL NOT NULL DEFAULT 1.0,
      backoff_max REAL NOT NULL DEFAULT 60.0,
      storm_window_sec INTEGER NOT NULL DEFAULT 600,
      storm_max_restarts INTEGER NOT NULL DEFAULT 10,
      timeout_seconds INTEGER NOT NULL DEFAULT 0,
      confirm_before_run INTEGER NOT NULL DEFAULT 0,
      allow_concurrent INTEGER NOT NULL DEFAULT 0,
      history_limit INTEGER NOT NULL DEFAULT 50,
      stop_signal TEXT NOT NULL DEFAULT 'TERM',
      stop_wait_seconds INTEGER NOT NULL DEFAULT 10,
      stop_as_group INTEGER NOT NULL DEFAULT 1,
      kill_as_group INTEGER NOT NULL DEFAULT 1,
      log_path TEXT, log_merge_stderr INTEGER NOT NULL DEFAULT 1,
      log_stderr_path TEXT,
      log_max_bytes INTEGER NOT NULL DEFAULT 10485760,
      log_backups INTEGER NOT NULL DEFAULT 3,
      log_rotate_policy TEXT NOT NULL DEFAULT 'size',
      run_total INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS live (
      program_id INTEGER PRIMARY KEY REFERENCES program(id) ON DELETE CASCADE,
      app_boot_id TEXT NOT NULL,
      state TEXT NOT NULL,
      pid INTEGER, pgid INTEGER,
      proc_start_time REAL,
      started_at REAL, retry_count INTEGER NOT NULL DEFAULT 0,
      stop_requested INTEGER NOT NULL DEFAULT 0,
      run_id INTEGER,
      needs_restart INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS run (
      id INTEGER PRIMARY KEY,
      program_id INTEGER NOT NULL REFERENCES program(id) ON DELETE CASCADE,
      trigger TEXT NOT NULL,
      pid INTEGER, started_at REAL NOT NULL, ended_at REAL,
      exit_code INTEGER, term_signal INTEGER,
      outcome TEXT,
      log_path TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_run_program_time ON run(program_id, started_at DESC);

    CREATE TABLE IF NOT EXISTS event (
      id INTEGER PRIMARY KEY, ts REAL NOT NULL,
      level TEXT NOT NULL,
      program_id INTEGER, type TEXT NOT NULL, detail_json TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_event_time ON event(ts DESC);

    CREATE TABLE IF NOT EXISTS setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """
}
