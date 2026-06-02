#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <openssl/evp.h>
#include <openssl/err.h>
#include <openssl/crypto.h> /* Required for OPENSSL_cleanse */
#include <limits.h>

/* =========================================================
 * Constants
 * ========================================================= */
#define AES_256_KEY_SIZE    32
#define AES_BLOCK_SIZE      16
#define MAX_PATH_LEN        512
#define MAX_PHRASE_LEN      256
#define SHA256_DIGEST_LEN   32

/* =========================================================
 * Error Handling
 * ========================================================= */
void handle_errors(const char *msg) {
    fprintf(stderr, "[ERROR] %s\n", msg);
    ERR_print_errors_fp(stderr);
    abort();
}

/* =========================================================
 * File Utility Functions
 * ========================================================= */
int file_exists(const char *filename) {
    struct stat buffer;
    return (stat(filename, &buffer) == 0);
}

int is_regular_file(const char *path) {
    struct stat statbuf;
    if (stat(path, &statbuf) != 0)
        return 0;
    return S_ISREG(statbuf.st_mode);
}

/* =========================================================
 * Secure phrase verification using EVP SHA-256 (OpenSSL 3.0+)
 * ========================================================= */
int verify_phrase(const char *input) {
    const unsigned char expected_hash[SHA256_DIGEST_LEN] = {
        0x9f, 0x4e, 0x2a, 0x1b, 0x8c, 0x3d, 0x7e, 0x5f,
        0xa0, 0x6b, 0x9c, 0x4d, 0x2e, 0x8f, 0x1a, 0x3c,
        0x5b, 0x7d, 0x9e, 0x0f, 0x2a, 0x4c, 0x6e, 0x8f,
        0x1b, 0x3d, 0x5f, 0x7a, 0x9c, 0x2e, 0x4a, 0x6e
    };

    unsigned char input_hash[SHA256_DIGEST_LEN];
    unsigned int hash_len = 0;
    int success = 0;

    /* Use modern EVP API instead of deprecated SHA256() */
    EVP_MD_CTX *mdctx = EVP_MD_CTX_new();
    if (!mdctx) {
        fprintf(stderr, "[ERROR] Failed to create digest context\n");
        return 0;
    }

    if (EVP_DigestInit_ex(mdctx, EVP_sha256(), NULL) != 1 ||
        EVP_DigestUpdate(mdctx, input, strlen(input)) != 1 ||
        EVP_DigestFinal_ex(mdctx, input_hash, &hash_len) != 1) {
        fprintf(stderr, "[ERROR] SHA256 hashing failed\n");
        EVP_MD_CTX_free(mdctx);
        return 0;
    }
    EVP_MD_CTX_free(mdctx);

    /* Constant time comparison to prevent timing side-channel attacks */
    int diff = 0;
    for (int i = 0; i < SHA256_DIGEST_LEN; i++) {
        diff |= (input_hash[i] ^ expected_hash[i]);
    }
    success = (diff == 0);

    /* Clean up temporary hash memory */
    OPENSSL_cleanse(input_hash, sizeof(input_hash));

    return success;
}

/* =========================================================
 * Dynamic File List Management
 * ========================================================= */
typedef struct {
    char **names;
    int    count;
    int    capacity;
} FileList;

FileList *filelist_create(void) {
    FileList *list = malloc(sizeof(FileList));
    if (!list) return NULL;

    list->capacity = 16;
    list->count    = 0;
    list->names    = malloc(list->capacity * sizeof(char *));

    if (!list->names) {
        free(list);
        return NULL;
    }

    return list;
}

int filelist_add(FileList *list, const char *name) {
    if (list->count >= list->capacity) {
        int new_capacity   = list->capacity * 2;
        char **new_names   = realloc(list->names, new_capacity * sizeof(char *));
        if (!new_names) return 0;

        list->names    = new_names;
        list->capacity = new_capacity;
    }

    list->names[list->count] = malloc(strlen(name) + 1);
    if (!list->names[list->count]) return 0;

    strcpy(list->names[list->count], name);
    list->count++;
    return 1;
}

void filelist_free(FileList *list) {
    if (!list) return;
    for (int i = 0; i < list->count; i++) {
        free(list->names[i]);
    }
    free(list->names);
    free(list);
}

/* =========================================================
 * Decrypt a single file safely
 * ========================================================= */
int decrypt_file(const char *filename, const unsigned char *key, int key_len) {
    if (key_len != AES_256_KEY_SIZE) {
        fprintf(stderr, "[ERROR] Key must be exactly %d bytes (got %d)\n", AES_256_KEY_SIZE, key_len);
        return 0;
    }

    FILE *in_file = fopen(filename, "rb");
    if (!in_file) {
        fprintf(stderr, "[ERROR] Failed to open '%s' for reading.\n", filename);
        return 0;
    }

    /* Get file size safely */
    if (fseek(in_file, 0, SEEK_END) != 0) {
        fprintf(stderr, "[ERROR] fseek failed on '%s'\n", filename);
        fclose(in_file);
        return 0;
    }

    long raw_file_size = ftell(in_file);
    if (raw_file_size < 0) {
        fprintf(stderr, "[ERROR] ftell failed on '%s'\n", filename);
        fclose(in_file);
        return 0;
    }
    size_t file_size = (size_t)raw_file_size;
    rewind(in_file);

    if (file_size <= AES_BLOCK_SIZE) {
        fprintf(stderr, "[ERROR] File '%s' is too small (size %zu).\n", filename, file_size);
        fclose(in_file);
        return 0;
    }

    /* Read IV */
    unsigned char iv[AES_BLOCK_SIZE];
    if (fread(iv, 1, AES_BLOCK_SIZE, in_file) != AES_BLOCK_SIZE) {
        fprintf(stderr, "[ERROR] Failed to read IV from '%s'\n", filename);
        fclose(in_file);
        return 0;
    }

    size_t cipher_size = file_size - AES_BLOCK_SIZE;
    
    if (cipher_size > INT_MAX) {
        fprintf(stderr, "[ERROR] File '%s' is too large to decrypt.\n", filename);
        fclose(in_file);
        return 0;
    }

    unsigned char *cipher = malloc(cipher_size);
    if (!cipher) {
        fprintf(stderr, "[ERROR] Memory allocation failed for cipher buffer.\n");
        fclose(in_file);
        return 0;
    }

    size_t bytes_read = fread(cipher, 1, cipher_size, in_file);
    fclose(in_file);

    if (bytes_read != cipher_size) {
        fprintf(stderr, "[ERROR] Read size mismatch on '%s'\n", filename);
        free(cipher);
        return 0;
    }

    /* Allocate plaintext buffer with padding room */
    unsigned char *plaintext = malloc(cipher_size + EVP_MAX_BLOCK_LENGTH);
    if (!plaintext) {
        fprintf(stderr, "[ERROR] Memory allocation failed for plaintext buffer.\n");
        free(cipher);
        return 0;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        free(cipher);
        free(plaintext);
        handle_errors("Failed to create EVP_CIPHER_CTX");
    }

    int success = 1;
    int len = 0;
    int plaintext_len = 0;

    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, key, iv) != 1) {
        fprintf(stderr, "[ERROR] EVP_DecryptInit_ex failed for '%s'\n", filename);
        success = 0;
        goto cleanup;
    }

    if (EVP_DecryptUpdate(ctx, plaintext, &len, cipher, (int)cipher_size) != 1) {
        fprintf(stderr, "[ERROR] EVP_DecryptUpdate failed for '%s'\n", filename);
        success = 0;
        goto cleanup;
    }
    plaintext_len = len;

    if (EVP_DecryptFinal_ex(ctx, plaintext + plaintext_len, &len) != 1) {
        fprintf(stderr, "[ERROR] Decryption failed for '%s'. Incorrect key or corrupted data.\n", filename);
        /* Clear internal OpenSSL error queue so subsequent runs aren't polluted */
        ERR_clear_error();
        success = 0;
        goto cleanup;
    }
    plaintext_len += len;

    /* 
     * Safe Write: Ensure the temp filename construction does not truncate
     */
    char tmp_filename[MAX_PATH_LEN];
    int printed = snprintf(tmp_filename, sizeof(tmp_filename), "%s.tmp", filename);
    if (printed < 0 || (size_t)printed >= sizeof(tmp_filename)) {
        fprintf(stderr, "[ERROR] Path too long to construct temp file for '%s'\n", filename);
        success = 0;
        goto cleanup;
    }

    FILE *out_file = fopen(tmp_filename, "wb");
    if (!out_file) {
        fprintf(stderr, "[ERROR] Failed to open temp file '%s' for writing.\n", tmp_filename);
        success = 0;
        goto cleanup;
    }

    size_t bytes_written = fwrite(plaintext, 1, (size_t)plaintext_len, out_file);
    fclose(out_file);

    if (bytes_written != (size_t)plaintext_len) {
        fprintf(stderr, "[ERROR] Write error on temp file '%s'\n", tmp_filename);
        remove(tmp_filename);
        success = 0;
        goto cleanup;
    }

    /* Replace original file with decrypted content */
    if (rename(tmp_filename, filename) != 0) {
        fprintf(stderr, "[ERROR] Failed to replace original file with decrypted content.\n");
        remove(tmp_filename);
        success = 0;
        goto cleanup;
    }

    printf("[OK] Successfully decrypted: %s\n", filename);

cleanup:
    EVP_CIPHER_CTX_free(ctx);
    free(cipher);
    
    /* Cleanse decrypted data before freeing */
    if (plaintext) {
        OPENSSL_cleanse(plaintext, cipher_size + EVP_MAX_BLOCK_LENGTH);
        free(plaintext);
    }
    return success;
}

/* =========================================================
 * Collect files from current directory
 * ========================================================= */
FileList *collect_files(const char **exclude_list, int exclude_count) {
    DIR *dir = opendir(".");
    if (!dir) {
        perror("[ERROR] Could not open current directory");
        return NULL;
    }

    FileList *list = filelist_create();
    if (!list) {
        closedir(dir);
        fprintf(stderr, "[ERROR] Failed to create file list\n");
        return NULL;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!is_regular_file(entry->d_name))
            continue;

        int excluded = 0;
        for (int i = 0; i < exclude_count; i++) {
            if (strcmp(entry->d_name, exclude_list[i]) == 0) {
                excluded = 1;
                break;
            }
        }

        if (excluded)
            continue;

        if (!filelist_add(list, entry->d_name)) {
            fprintf(stderr, "[ERROR] Failed to add '%s' to file list\n", entry->d_name);
            filelist_free(list);
            closedir(dir);
            return NULL;
        }
    }

    closedir(dir);
    return list;
}

/* =========================================================
 * Load key from file securely
 * ========================================================= */
unsigned char *load_key(const char *key_filename, int *key_len) {
    if (!file_exists(key_filename)) {
        fprintf(stderr, "[ERROR] Key file '%s' not found.\n", key_filename);
        return NULL;
    }

    FILE *key_file = fopen(key_filename, "rb");
    if (!key_file) {
        perror("[ERROR] Failed to open key file");
        return NULL;
    }

    if (fseek(key_file, 0, SEEK_END) != 0) {
        fclose(key_file);
        fprintf(stderr, "[ERROR] fseek failed on key file\n");
        return NULL;
    }

    long key_size = ftell(key_file);
    if (key_size < AES_256_KEY_SIZE) {
        fclose(key_file);
        fprintf(stderr, "[ERROR] Key file is too small\n");
        return NULL;
    }

    rewind(key_file);

    unsigned char *key = malloc(AES_256_KEY_SIZE);
    if (!key) {
        fclose(key_file);
        fprintf(stderr, "[ERROR] Memory allocation failed for key\n");
        return NULL;
    }

    size_t bytes_read = fread(key, 1, AES_256_KEY_SIZE, key_file);
    fclose(key_file);

    if (bytes_read != AES_256_KEY_SIZE) {
        fprintf(stderr, "[ERROR] Failed to read %d bytes from key file\n", AES_256_KEY_SIZE);
        free(key);
        return NULL;
    }

    *key_len = AES_256_KEY_SIZE;
    return key;
}

/* =========================================================
 * Main Entry Point
 * ========================================================= */
int main(void) {
    const char *exclude_files[] = {
        "exploit.py",
        "thekey.key",
        "decrypt.c",
        "decrypt" 
    };
    int exclude_count = sizeof(exclude_files) / sizeof(exclude_files[0]);

    FileList *files = collect_files(exclude_files, exclude_count);
    if (!files) {
        return 1;
    }

    if (files->count == 0) {
        printf("[INFO] No files found to decrypt.\n");
        filelist_free(files);
        return 0;
    }

    printf("\n[INFO] Files found for decryption:\n");
    for (int i = 0; i < files->count; i++) {
        printf("       [%d] %s\n", i + 1, files->names[i]);
    }
    printf("\n");

    int key_len = 0;
    unsigned char *secret_key = load_key("thekey.key", &key_len);
    if (!secret_key) {
        filelist_free(files);
        return 1;
    }

    char user_phrase[MAX_PHRASE_LEN];
    printf("Enter the SECRET phrase: \n> ");
    fflush(stdout);

    if (fgets(user_phrase, sizeof(user_phrase), stdin) == NULL) {
        fprintf(stderr, "[ERROR] Failed to read input\n");
        OPENSSL_cleanse(secret_key, key_len);
        free(secret_key);
        filelist_free(files);
        return 1;
    }

    user_phrase[strcspn(user_phrase, "\n")] = '\0';

    if (!verify_phrase(user_phrase)) {
        printf("[DENIED] Incorrect phrase. Access denied.\n");
        OPENSSL_cleanse(user_phrase, sizeof(user_phrase));
        OPENSSL_cleanse(secret_key, key_len);
        free(secret_key);
        filelist_free(files);
        return 1;
    }

    /* Wipe the plain-text secret phrase as soon as it is verified */
    OPENSSL_cleanse(user_phrase, sizeof(user_phrase));

    printf("[OK] Phrase accepted. Starting decryption...\n\n");

    /* Initialize OpenSSL configuration */
    OPENSSL_init_crypto(OPENSSL_INIT_LOAD_CONFIG |
                        OPENSSL_INIT_ADD_ALL_CIPHERS |
                        OPENSSL_INIT_ADD_ALL_DIGESTS, NULL);

    int success_count = 0;
    int fail_count    = 0;

    for (int i = 0; i < files->count; i++) {
        if (decrypt_file(files->names[i], secret_key, key_len)) {
            success_count++;
        } else {
            fail_count++;
        }
    }

    printf("\n========================================\n");
    printf("  Decryption Complete\n");
    printf("  Successful : %d\n", success_count);
    printf("  Failed     : %d\n", fail_count);
    printf("========================================\n");

    /* Securely clear and free key */
    OPENSSL_cleanse(secret_key, key_len);
    free(secret_key);
    filelist_free(files);

    return (fail_count > 0) ? 1 : 0;
}