/*
 * libbwdpi_stub.c — clean-room no-op replacement for the proprietary ASUS
 * libbwdpi.so (the Trend Micro DPI control library).
 *
 * Purpose (v25 de-blobbing): the DPI engine (wred, dcd, libshn, usr/bwdpi) is
 * stripped from the open-init image, but several KEEP binaries still
 * DT_NEEDED libbwdpi.so (rc, wps_pbcd, httpd, wlceventd via libwebapi, etc.).
 * Removing the .so outright would leave them unloadable. This stub provides a
 * valid 32-bit ARM ELF shared object exporting EXACTLY the symbols those
 * surviving consumers reference (verified by intersecting their undefined
 * dynsyms with the original libbwdpi exports): 49 functions as no-ops and 6
 * data objects as zero-filled storage. No DPI behaviour, no network, no eula,
 * no logging; every entry point returns success/zero so callers proceed as
 * if DPI is simply disabled. No SONAME (the original has none).
 *
 * Clean-room: authored from the public symbol NAMES only; holds none of the
 * proprietary implementation. All functions are trivial stubs.
 */

/* ---- 6 OBJECT (data) symbols — zero-filled, generously sized ------------- */
char file_path[1024];
int  s_tcode_blacklist_tuple;
int  s_tcode_tuple;
int  s_tuple;
int  vpnc_profile[64];
int  vpnc_profile_num;

/* ---- 49 FUNC symbols — no-ops ------------------------------------------- */
int AiProtectionMonitor_InfectedEvent(void) { return 0; }
int AiProtectionMonitor_mail_log(void)      { return 0; }
int MobileDevMode_restart(void)             { return 0; }
int WRS_WBL_DEL_LIST(void)                  { return 0; }
int WRS_WBL_GET_PATH(void)                  { return 0; }
int WRS_WBL_WRITE_LIST(void)                { return 0; }
int auto_sig_check(void)                    { return 0; }
int check_tcode_blacklist(void)             { return 0; }
int check_tdts_module_exist(void)           { return 0; }
int data_collect_main(void)                 { return 0; }
int device_info_main(void)                  { return 0; }
int device_main(void)                       { return 0; }
int dump_dpi_support(void)                  { return 0; }
int free_app_cat(void)                      { return 0; }
int free_app_inf(void)                      { return 0; }
int free_rule_db(void)                      { return 0; }
int get_anomaly_main(void)                  { return 0; }
int get_app_patrol_main(void)               { return 0; }
int get_fw_app_bw_clear(void)               { return 0; }
int get_fw_mesh_extender(void)              { return 0; }
int get_fw_user_domain_list(void)           { return 0; }
int get_fw_user_list(void)                  { return 0; }
int get_fw_vp_list(void)                    { return 0; }
int get_fw_wrs_url_list(void)               { return 0; }
int get_vp(void)                            { return 0; }
int init_app_cat(void)                      { return 0; }
int init_app_inf(void)                      { return 0; }
int init_rule_db(void)                      { return 0; }
int mesh_set_extender(void)                 { return 0; }
int qosd_main(void)                         { return 0; }
int redirect_page_status(void)              { return 0; }
int run_dpi_engine_service(void)            { return 0; }
int search_app_cat(void)                    { return 0; }
int search_app_inf(void)                    { return 0; }
int setup_wrs_conf(void)                    { return 0; }
int start_dc(void)                          { return 0; }
int start_dpi_engine_service(void)          { return 0; }
int start_wrs(void)                         { return 0; }
int start_wrs_wbl_service(void)             { return 0; }
int stat_main(void)                         { return 0; }
int stop_bwdpi_wred_alive(void)             { return 0; }
int stop_dpi_engine_service(void)           { return 0; }
int tdts_check_wan_changed(void)            { return 0; }
int tm_eula_check(void)                     { return 0; }
int tm_qos_main(void)                       { return 0; }
int web_history_save(void)                  { return 0; }
int wrs_app_main(void)                      { return 0; }
int wrs_main(void)                          { return 0; }
int wrs_url_main(void)                      { return 0; }
