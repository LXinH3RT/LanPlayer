/* Probe: which path spelling does libsmb2 accept for the share root?
 * Build: zig cc -o build\smb_probe.exe tool\smb_probe.c build\win-x64\smb2\libsmb2.a -lws2_32
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>

#include <smb2/libsmb2.h>
#include <smb2/smb2.h>

int main(void)
{
    WSADATA data;
    WSAStartup(MAKEWORD(2, 2), &data);

    const char *server = "192.168.1.10";
    const char *share = "\xE5\xA4\x9A\xE5\xAA\x92\xE4\xBD\x93\xE6\x96\x87\xE4\xBB\xB6"; /* 共享 */
    const char *user = "share";
    const char *pass = "share";

    struct smb2_context *smb2 = smb2_init_context();
    smb2_set_timeout(smb2, 10);
    smb2_set_security_mode(smb2, SMB2_NEGOTIATE_SIGNING_ENABLED);
    smb2_set_user(smb2, user);
    smb2_set_password(smb2, pass);

    if (smb2_connect_share(smb2, server, share, user) < 0) {
        printf("connect_share FAILED: %s\n", smb2_get_error(smb2));
        return 1;
    }
    printf("connect_share OK (share=%s)\n", share);

    const char *paths[] = {"/", "", "\\", "*", ".", "/.", "/\\"};
    for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        struct smb2dir *dir = smb2_opendir(smb2, paths[i]);
        if (dir) {
            struct smb2dirent *ent;
            int n = 0;
            printf("opendir(\"%s\") OK", paths[i]);
            while ((ent = smb2_readdir(smb2, dir)) != NULL && n < 5) {
                printf(" | %s", ent->name);
                n++;
            }
            printf(" (%d shown)\n", n);
            smb2_closedir(smb2, dir);
        } else {
            printf("opendir(\"%s\") FAILED: %s\n", paths[i], smb2_get_error(smb2));
        }
    }
    /* sub directory and file spellings */
    const char *dirs[] = {"\xE7\x94\xB5\xE8\xA7\x86\xE5\x89\xA7", "/\xE7\x94\xB5\xE8\xA7\x86\xE5\x89\xA7"};
    for (unsigned i = 0; i < 2; i++) {
        struct smb2dir *dir = smb2_opendir(smb2, dirs[i]);
        printf("opendir(\"%s\") -> %s\n", dirs[i], dir ? "OK" : smb2_get_error(smb2));
        if (dir) smb2_closedir(smb2, dir);
    }
    const char *files[] = {
        "\xE5\x8D\x97\xE5\xBC\x80\xE5\xA4\xA7\xE5\xAD\xA6\xE8\x89\xBE\xE8\xB7\x83\xE8\xBF\x9B\xE6\x95\x99\xE6\x8E\x88\xE7\x88\xB1\xE5\x9B\xBD\xE6\xBC\x94\xE8\xAE\xB2.mp4",
        "/\xE5\x8D\x97\xE5\xBC\x80\xE5\xA4\xA7\xE5\xAD\xA6\xE8\x89\xBE\xE8\xB7\x83\xE8\xBF\x9B\xE6\x95\x99\xE6\x8E\x88\xE7\x88\xB1\xE5\x9B\xBD\xE6\xBC\x94\xE8\xAE\xB2.mp4"};
    for (unsigned i = 0; i < 2; i++) {
        struct smb2fh *fh = smb2_open(smb2, files[i], O_RDONLY);
        printf("open(\"%s\") -> %s\n", i ? "/name" : "name", fh ? "OK" : smb2_get_error(smb2));
        if (fh) {
            unsigned char buf[16];
            int n = smb2_read(smb2, fh, buf, sizeof(buf));
            printf("   read %d bytes\n", n);
            smb2_close(smb2, fh);
        }
    }

    smb2_destroy_context(smb2);
    return 0;
}
