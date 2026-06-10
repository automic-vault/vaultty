#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <stdlib.h>
#include <string.h>

static NSMutableDictionary *vaultty_password_query(NSString *service,
                                                   NSString *account) {
  NSMutableDictionary *query = [@{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: service,
    (__bridge id)kSecAttrAccount: account,
  } mutableCopy];

  SecKeychainRef defaultKeychain = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  OSStatus status = SecKeychainCopyDefault(&defaultKeychain);
#pragma clang diagnostic pop
  if (status == errSecSuccess && defaultKeychain != NULL) {
    query[(__bridge id)kSecUseKeychain] = CFBridgingRelease(defaultKeychain);
  }

  return query;
}

char *vaultty_copy_generic_password(const char *service_cstr,
                                    const char *account_cstr,
                                    char **error_cstr,
                                    int *status_out) {
  @autoreleasepool {
    if (error_cstr != NULL) {
      *error_cstr = NULL;
    }
    if (status_out != NULL) {
      *status_out = errSecSuccess;
    }

    if (service_cstr == NULL || account_cstr == NULL) {
      if (error_cstr != NULL) {
        *error_cstr = strdup("invalid keychain lookup arguments");
      }
      return NULL;
    }

    NSString *service = [NSString stringWithUTF8String:service_cstr];
    NSString *account = [NSString stringWithUTF8String:account_cstr];
    if (service == nil || account == nil) {
      if (error_cstr != NULL) {
        *error_cstr = strdup("keychain lookup arguments must be UTF-8");
      }
      return NULL;
    }

    NSMutableDictionary *query = vaultty_password_query(service, account);
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status_out != NULL) {
      *status_out = (int)status;
    }
    if (status != errSecSuccess) {
      if (error_cstr != NULL) {
        NSString *message = (__bridge_transfer NSString *)
            SecCopyErrorMessageString(status, NULL);
        if (message == nil) {
          message = [NSString stringWithFormat:@"keychain lookup failed (%d)",
                                                (int)status];
        }
        *error_cstr = strdup(message.UTF8String);
      }
      return NULL;
    }

    NSData *data = CFBridgingRelease(result);
    if (data == nil) {
      if (error_cstr != NULL) {
        *error_cstr = strdup("keychain lookup did not return data");
      }
      return NULL;
    }

    char *copy = calloc(data.length + 1, sizeof(char));
    if (copy == NULL) {
      if (error_cstr != NULL) {
        *error_cstr = strdup("failed to allocate keychain buffer");
      }
      return NULL;
    }
    memcpy(copy, data.bytes, data.length);
    copy[data.length] = '\0';
    return copy;
  }
}

void vaultty_free_c_string(char *value) {
  if (value != NULL) {
    free(value);
  }
}
