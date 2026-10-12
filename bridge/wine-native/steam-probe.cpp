/* Read-only check of the current native Steam session through Wine's LSC bridge.
 * No account IDs, authentication tickets, credentials, or callback bodies are
 * requested or printed. All handles created here are released before exit.
 */
#include <windows.h>
#include <cstdio>
#include <cstring>

#define STEAM_API_NODLL
#include "steam_api.h"

using CreateInterface = void *(__cdecl *)(const char *, int *);
using WineVersion = const char *(__cdecl *)();

int main()
{
    std::printf("probe_pointer_bits=%zu\n", sizeof(void *) * 8);
    std::fflush(stdout);
    auto get_version = reinterpret_cast<WineVersion>(
        GetProcAddress(GetModuleHandleA("ntdll.dll"), "wine_get_version"));
    if (!get_version)
    {
        std::printf("error=wine_version_unavailable\n");
        return 10;
    }
    const char *version = get_version();
    std::printf("wine_version=%s\n", version);
    if (std::strcmp(version, "11.17"))
    {
        std::printf("error=unexpected_wine_version\n");
        return 11;
    }
#ifdef _WIN64
    const char *module_name = "steamclient64.dll";
#else
    const char *module_name = "steamclient.dll";
#endif
    HMODULE forwarder = LoadLibraryA(module_name);
    if (!forwarder)
    {
        std::printf("error=forwarder_load_failed windows_error=%lu\n", GetLastError());
        return 12;
    }
    auto create = reinterpret_cast<CreateInterface>(GetProcAddress(forwarder, "CreateInterface"));
    if (!create || !GetModuleHandleA("lsteamclient.dll"))
    {
        std::printf("error=lsteamclient_forwarder_resolution_failed windows_error=%lu\n", GetLastError());
        FreeLibrary(forwarder);
        return 13;
    }
    std::printf("lsteamclient_module=loaded\n");
    std::fflush(stdout);
    int interface_error = -1;
    auto client = static_cast<ISteamClient *>(create(STEAMCLIENT_INTERFACE_VERSION, &interface_error));
    if (!client)
    {
        std::printf("error=steam_client_interface_unavailable interface_error=%d\n", interface_error);
        FreeLibrary(forwarder);
        return 14;
    }
    std::printf("steam_client_interface=%s\n", STEAMCLIENT_INTERFACE_VERSION);
    std::fflush(stdout);
    HSteamPipe pipe = client->CreateSteamPipe();
    if (!pipe)
    {
        std::printf("error=native_steam_pipe_unavailable\n");
        FreeLibrary(forwarder);
        return 15;
    }
    HSteamUser user = client->ConnectToGlobalUser(pipe);
    if (!user)
    {
        std::printf("error=native_steam_user_unavailable\n");
        client->BReleaseSteamPipe(pipe);
        FreeLibrary(forwarder);
        return 16;
    }
    ISteamUser *steam_user = client->GetISteamUser(user, pipe, STEAMUSER_INTERFACE_VERSION);
    ISteamApps *apps = client->GetISteamApps(user, pipe, STEAMAPPS_INTERFACE_VERSION);
    bool logged_on = steam_user && steam_user->BLoggedOn();
    bool subscribed = apps && apps->BIsSubscribedApp(3393110);
    std::printf("steam_user_interface_available=%d\n", steam_user != nullptr);
    std::printf("native_steam_logged_on=%d\n", logged_on);
    std::printf("steam_apps_interface_available=%d\n", apps != nullptr);
    std::printf("aion2_subscription_visible=%d\n", subscribed);
    client->ReleaseUser(pipe, user);
    bool released = client->BReleaseSteamPipe(pipe);
    std::printf("probe_pipe_released=%d\n", released);
    std::fflush(stdout);
    FreeLibrary(forwarder);
    return logged_on && apps && released ? 0 : 17;
}
