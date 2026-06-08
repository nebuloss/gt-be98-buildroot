/*
 * libbwdpi_sql_stub.c — clean-room no-op replacement for the proprietary ASUS
 * libbwdpi_sql.so (the DPI monitor/SQLite reporting helper).
 *
 * Stripped alongside the DPI engine in v25. Surviving consumers (httpd and
 * libwebapi.so) DT_NEEDED this .so; the 8 functions below are EXACTLY the
 * symbols they reference (verified via dynsym intersection). All are no-ops:
 * the *_to_json / *_info / *_ips / *_nonips / *_stat readers return 0 so the
 * webui simply sees an empty/zero DPI monitor dataset. No SONAME.
 *
 * Clean-room: authored from public symbol NAMES only.
 */

int bwdpi_cgi_mon_del_db(void)  { return 0; }
int bwdpi_cgi_mon_to_json(void) { return 0; }
int bwdpi_maclist_db(void)      { return 0; }
int bwdpi_monitor_info(void)    { return 0; }
int bwdpi_monitor_ips(void)     { return 0; }
int bwdpi_monitor_nonips(void)  { return 0; }
int bwdpi_monitor_stat(void)    { return 0; }
int get_web_hook(void)          { return 0; }
