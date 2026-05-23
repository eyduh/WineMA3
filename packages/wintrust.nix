{ pkgs, runCommand }:
runCommand "wintrust-stub" {
  nativeBuildInputs = [ pkgs.pkgsCross.mingwW64.stdenv.cc ];
} ''
  mkdir -p $out

  cat > wintrust_stub.c <<'EOF'
  #include <stdarg.h>
  #include <windef.h>
  #include <winbase.h>
  #include <wintrust.h>

  LONG WINAPI WinVerifyTrust(HWND hwnd, GUID *action_id, LPVOID data)
  {
      SetLastError(ERROR_SUCCESS);
      return ERROR_SUCCESS;
  }

  HRESULT WINAPI WinVerifyTrustEx(HWND hwnd, GUID *action_id, WINTRUST_DATA *data)
  {
      SetLastError(ERROR_SUCCESS);
      return S_OK;
  }

  BOOL WINAPI WintrustAddActionID(GUID *action_id, DWORD flags, CRYPT_REGISTER_ACTIONID *action)
  {
      SetLastError(ERROR_SUCCESS);
      return TRUE;
  }

  BOOL WINAPI WintrustRemoveActionID(GUID *action_id)
  {
      SetLastError(ERROR_SUCCESS);
      return TRUE;
  }

  HRESULT WINAPI DllRegisterServer(void)
  {
      return S_OK;
  }

  HRESULT WINAPI DllUnregisterServer(void)
  {
      return S_OK;
  }
  EOF

  cat > wintrust_stub.def <<'EOF'
  LIBRARY wintrust.dll
  EXPORTS
      WinVerifyTrust
      WinVerifyTrustEx
      WintrustAddActionID
      WintrustRemoveActionID
      DllRegisterServer
      DllUnregisterServer
  EOF

  x86_64-w64-mingw32-gcc -shared -o $out/wintrust.dll wintrust_stub.c wintrust_stub.def -Wl,--kill-at
''
