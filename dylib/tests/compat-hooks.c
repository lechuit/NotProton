// Exercise actual hooks with synthetic managers and mapping API callbacks.
#include "../feats/compat.c"
#include "../hooks/hook_compat.c"

#include <stdio.h>

int np_log_level = -1;
FILE *np_log_file = NULL;
int np_log_first_hit(const void *anchor, unsigned long tag) { return 1; }
const char *np_home_dir(void) { return "/nonexistent"; }
void np_compatsvc_state_changed(void) {}

static const char native[] = "notproton-wine-native-wine-11.17";
static uint8_t manager[0x900], entries[2 * COMPAT_TOOL_STRIDE];
static const char *mapping[3];
static void *resolved;
static int maps, recursive, asynchronous, original_keeps;
static uint32_t mapped_appid, mapped_priority;
static uint64_t original_appid;
static const char *original_name;
static void *original_config;
static int original_priority;
static int failures;

static void check(int ok, const char *what) {
    if (!ok) { printf("FAIL %s\n", what); failures++; }
}
static void *get_mapping(void *mgr, uint32_t appid) { return mapping; }
static uint32_t get_platforms(void *mgr, uint32_t appid) { return COMPAT_PLATFORM_WINDOWS; }
static void *find_original(void *mgr, uint32_t appid) { return resolved; }
static uint64_t specify_original(void *mgr, uint64_t appid, const char *name, void *config, int priority) {
    original_appid = appid;
    original_name = name;
    original_config = config;
    original_priority = priority;
    if (original_keeps) mapping[0] = name;
    return 123;
}
static void set_mapping(void *mgr, uint32_t appid, const char *name, const char *config, uint32_t priority) {
    maps++;
    mapped_appid = appid;
    mapped_priority = priority;
    if (asynchronous) return;
    if (recursive) hook_InternalSpecifyCompatTool(mgr, appid, name, (void *)config, priority);
    mapping[0] = name;
}

int main(void) {
    np_compat_fallback_tool_name(); // complete the once-only registry read first
    g_tools = calloc(2, sizeof(*g_tools));
    g_tool_count = g_tool_cap = 2;
    strcpy(g_tools[0].name, "notproton");
    strcpy(g_tools[1].name, native);
    *(void **)(manager + COMPAT_MANAGER_TOOL_ARRAY_OFF) = entries;
    *(uint32_t *)(manager + COMPAT_MANAGER_TOOL_COUNT_OFF) = 2;
    *(const char **)(entries + COMPAT_TOOL_NAME_OFF) = g_tools[0].name;
    *(const char **)(entries + COMPAT_TOOL_STRIDE + COMPAT_TOOL_NAME_OFF) = g_tools[1].name;
    np_compat_set_app_mapping_fn((uintptr_t)get_mapping);
    np_compat_set_mapping_fn((uintptr_t)set_mapping);
    np_compat_set_valid_platforms_fn((uintptr_t)get_platforms);
    orig_FindToolForTargetApp = (void *)find_original;
    orig_InternalSpecifyCompatTool = (void *)specify_original;

    mapping[0] = native;
    resolved = NULL;
    check(hook_FindToolForTargetApp(manager, 3393110) == NULL, "unresolved explicit native engine never falls back to CrossOver");
    mapping[0] = "notproton-wine-wine-11.17";
    check(hook_FindToolForTargetApp(manager, 3393110) == NULL, "unresolved explicit raw engine never falls back");
    mapping[0] = NULL;
    check(hook_FindToolForTargetApp(manager, 3393110) == entries, "an unmapped Windows game keeps the existing fallback");
    mapping[0] = NP_COMPAT_TOOL_NONE;
    check(hook_FindToolForTargetApp(manager, 3393110) == NULL, "explicit no-tool remains honored");
    resolved = entries + COMPAT_TOOL_STRIDE;
    mapping[0] = native;
    check(hook_FindToolForTargetApp(manager, 3393110) == resolved, "resolved native engine is retained");

    mapping[0] = NULL;
    char config_marker[] = "original-config";
    check(hook_InternalSpecifyCompatTool(manager, 3393110, native, config_marker, 250) == 123, "selection preserves the original result");
    check(original_appid == 3393110 && original_name == native && original_config == config_marker && original_priority == 250,
          "all original setter arguments pass through exactly");
    check(maps == 1 && mapped_appid == 3393110 && mapped_priority == 250 && !strcmp(mapping[0], native),
          "discarded known native choice is repaired through per-app mapping API");
    maps = 0;
    original_keeps = 1;
    hook_InternalSpecifyCompatTool(manager, 3393110, native, NULL, 250);
    check(maps == 0, "an already stored choice is not rewritten");
    original_keeps = 0;
    mapping[0] = NULL;
    hook_InternalSpecifyCompatTool(manager, 3393110, "notproton-wine-native-unknown", NULL, 250);
    check(maps == 0, "unregistered IPC name cannot repair a mapping");
    hook_InternalSpecifyCompatTool(manager, 3393110, "notproton", NULL, 250);
    check(maps == 0, "CrossOver selection is not intercepted");
    hook_InternalSpecifyCompatTool(manager, 0, native, NULL, 75);
    check(maps == 0, "global defaults are not repaired");
    *(uint32_t *)(manager + COMPAT_MANAGER_TOOL_COUNT_OFF) = 1;
    hook_InternalSpecifyCompatTool(manager, 3393110, native, NULL, 250);
    check(maps == 0, "registry name missing from live manager cannot repair");
    *(uint32_t *)(manager + COMPAT_MANAGER_TOOL_COUNT_OFF) = 2;
    memset(np_repair_attempts, 0, sizeof np_repair_attempts);
    recursive = 1;
    hook_InternalSpecifyCompatTool(manager, 3393110, native, NULL, 250);
    check(maps == 1 && !np_mapping_repair && !strcmp(mapping[0], native), "reentrant mapping API does not loop");

    maps = recursive = 0;
    mapping[0] = NULL;
    memset(np_repair_attempts, 0, sizeof np_repair_attempts);
    g_set_mapping = NULL;
    hook_InternalSpecifyCompatTool(manager, 3393110, native, NULL, 250);
    check(!maps && !mapping[0] && !np_mapping_repair, "missing mapping API does not invent persistence");
    np_compat_set_mapping_fn((uintptr_t)set_mapping);
    asynchronous = 1;
    hook_InternalSpecifyCompatTool(manager, 3393110, native, NULL, 250);
    check(maps == 1 && !mapping[0], "queued repair remains pending until the client applies it");
    hook_InternalSpecifyCompatTool(manager, 3393110, native, NULL, 250); // drain the queued job
    hook_InternalSpecifyCompatTool(manager, 3393110, native, NULL, 250); // repeated failed delivery
    check(maps == 1 && !mapping[0], "asynchronous failed callbacks cannot enqueue an unbounded repair loop");

    np_log_file = tmpfile();
    np_log_level = NP_LVL_INFO;
    hook_InternalSpecifyCompatTool(manager, 3393110, "secret-ipc-name", (void *)"secret-config-token", 250);
    fflush(np_log_file);
    rewind(np_log_file);
    char log[2048] = {0};
    fread(log, 1, sizeof(log) - 1, np_log_file);
    check(strstr(log, "app 3393110") && strstr(log, "tool=unregistered") && !strstr(log, "secret"),
          "selection diagnostics contain safe identity and no arbitrary IPC/config strings");
    fclose(np_log_file);
    np_log_file = NULL;
    if (!failures) puts("==> compat hooks: fail-closed selection, native repair, reentrancy and safe logs pass");
    return failures ? 1 : 0;
}
