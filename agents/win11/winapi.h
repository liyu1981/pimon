// Minimal Windows SDK surface for the pimon Win11 agent.
//
// Translate-c target: x86_64-windows-gnu.  The legacy IP Helper table API is
// used deliberately: the newer MIB_IF_ROW2 contains bitfields and translate-c
// demotes it to an opaque type.

#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include <windows.h>
#include <pdh.h>
#include <dxgi1_4.h>
#include <iphlpapi.h>
