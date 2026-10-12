/* LSC can place SteamClient interfaces/vtables inside steamclient's .data.
 * Initializing one byte keeps the whole reserve present in the PE on disk.
 * This DLL has no executable entry point or imported libraries.
 */
unsigned char notproton_interface_reserve[65536] = {0x4e, 0x50};
