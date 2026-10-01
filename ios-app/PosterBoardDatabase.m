#import "PosterBoardDatabase.h"
#import <sqlite3.h>

@implementation PosterBoardDatabase

+ (BOOL)exec:(sqlite3 *)db sql:(const char *)sql error:(NSString **)error {
    char *message = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &message);
    if (rc == SQLITE_OK) return YES;
    if (error) {
        NSString *msg = message ? [NSString stringWithUTF8String:message] : @"SQLite error";
        *error = msg ?: @"SQLite error";
    }
    if (message) sqlite3_free(message);
    return NO;
}

+ (BOOL)hasTable:(sqlite3 *)db name:(const char *)name {
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT);
    BOOL found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    return found;
}

+ (BOOL)prepareDatabaseAtPath:(NSString *)path
                       walData:(NSData *)walData
                  wallpaperUUID:(NSString *)uuid
                       provider:(NSString *)provider
                          error:(NSString **)error {
    if (path.length == 0 || uuid.length == 0 || provider.length == 0) {
        if (error) *error = @"Invalid PosterBoard database arguments";
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *walPath = [path stringByAppendingString:@"-wal"];
    NSString *shmPath = [path stringByAppendingString:@"-shm"];

    // A stale -shm must never be carried into the rebuilt database.
    [fm removeItemAtPath:shmPath error:nil];
    if (walData.length > 0) {
        if (![walData writeToFile:walPath options:NSDataWritingAtomic error:nil]) {
            if (error) *error = @"Could not stage PosterBoard WAL";
            return NO;
        }
    } else {
        [fm removeItemAtPath:walPath error:nil];
    }

    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path.fileSystemRepresentation, &db,
                             SQLITE_OPEN_READWRITE, NULL);
    if (rc != SQLITE_OK || db == NULL) {
        if (error) {
            const char *msg = db ? sqlite3_errmsg(db) : "sqlite3_open_v2 failed";
            *error = [NSString stringWithUTF8String:msg] ?: @"SQLite open failed";
        }
        if (db) sqlite3_close(db);
        return NO;
    }

    BOOL ok = YES;
    NSString *localError = nil;

    if (![self exec:db sql:"PRAGMA busy_timeout=10000;" error:&localError]) ok = NO;

    // The live PosterBoard database is WAL-backed. Opening it with the staged
    // WAL lets SQLite recover the latest committed state before we mutate it.
    if (ok && ![self exec:db sql:"PRAGMA wal_checkpoint(FULL);" error:&localError]) ok = NO;

    if (ok && ![self hasTable:db name:"poster"]) localError = @"PosterBoard DB has no poster table";
    if (ok && ![self hasTable:db name:"posterAttributes"]) localError = @"PosterBoard DB has no posterAttributes table";
    if (ok && ![self hasTable:db name:"posterRoleMembership"]) localError = @"PosterBoard DB has no posterRoleMembership table";
    if (ok && localError != nil) ok = NO;

    sqlite3_stmt *stmt = NULL;
    long long nextPosterId = 0;
    long long nextSortKey = 0;

    if (ok) {
        const char *sql = "SELECT COALESCE(MAX(posterId),0) FROM poster";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
            sqlite3_step(stmt) != SQLITE_ROW) {
            localError = @"Could not read PosterBoard posterId sequence";
            ok = NO;
        } else {
            nextPosterId = sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt); stmt = NULL;
    }

    if (ok) {
        const char *sql =
            "SELECT COALESCE(MAX(roleSortKey),0) FROM posterRoleMembership "
            "WHERE roleId='PRPosterRoleLockScreen'";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
            sqlite3_step(stmt) != SQLITE_ROW) {
            localError = @"Could not read PosterBoard role sort key";
            ok = NO;
        } else {
            nextSortKey = sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt); stmt = NULL;
    }

    if (ok && ![self exec:db sql:"BEGIN IMMEDIATE;" error:&localError]) ok = NO;

    if (ok) {
        // Only one wallpaper is selected by the lock-screen role.
        const char *sql =
            "DELETE FROM posterAttributes "
            "WHERE roleId='PRPosterRoleLockScreen' "
            "AND attributeIdentifier='SELECTED'";
        if (![self exec:db sql:sql error:&localError]) ok = NO;
    }

    long long existingPosterId = 0;
    if (ok) {
        const char *sql = "SELECT posterId FROM poster WHERE UUID=? LIMIT 1";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            localError = @"Could not query existing PosterBoard wallpaper";
            ok = NO;
        } else {
            sqlite3_bind_text(stmt, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_ROW) existingPosterId = sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt); stmt = NULL;
    }

    if (ok) {
        if (existingPosterId > 0) {
            const char *sql = "UPDATE poster SET providerId=? WHERE posterId=?";
            if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
                localError = @"Could not update PosterBoard wallpaper row";
                ok = NO;
            } else {
                sqlite3_bind_text(stmt, 1, provider.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_int64(stmt, 2, existingPosterId);
                if (sqlite3_step(stmt) != SQLITE_DONE) {
                    localError = @"Could not update PosterBoard wallpaper provider";
                    ok = NO;
                }
            }
            sqlite3_finalize(stmt); stmt = NULL;
        } else {
            nextPosterId++;
            const char *sql = "INSERT INTO poster (posterId, UUID, providerId) VALUES (?,?,?)";
            if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
                localError = @"Could not prepare PosterBoard wallpaper insert";
                ok = NO;
            } else {
                sqlite3_bind_int64(stmt, 1, nextPosterId);
                sqlite3_bind_text(stmt, 2, uuid.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 3, provider.UTF8String, -1, SQLITE_TRANSIENT);
                if (sqlite3_step(stmt) != SQLITE_DONE) {
                    localError = [NSString stringWithFormat:@"PosterBoard insert failed: %s", sqlite3_errmsg(db)];
                    ok = NO;
                }
            }
            sqlite3_finalize(stmt); stmt = NULL;
        }
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *metadata = [NSString stringWithFormat:
        @"{\"creationDate\":%.6f,\"extensionAvailable\":true,"
         "\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\","
         "\"lastActivatedDate\":%.6f,\"lastSelectedDate\":%.6f}",
        now, now + 0.0001, now + 0.00001];

    if (ok) {
        const char *sql =
            "UPDATE posterAttributes SET attributePayload=? "
            "WHERE posterUUID=? AND roleId='PRPosterRoleLockScreen' "
            "AND attributeIdentifier='PRPosterRoleAttributeTypeUsageMetadata'";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            localError = @"Could not prepare PosterBoard metadata update";
            ok = NO;
        } else {
            sqlite3_bind_text(stmt, 1, metadata.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) != SQLITE_DONE) {
                localError = @"Could not update PosterBoard metadata";
                ok = NO;
            } else if (sqlite3_changes(db) == 0) {
                sqlite3_finalize(stmt); stmt = NULL;
                const char *ins =
                    "INSERT INTO posterAttributes "
                    "(posterUUID,roleId,attributeIdentifier,attributePayload) VALUES "
                    "(?,'PRPosterRoleLockScreen','PRPosterRoleAttributeTypeUsageMetadata',?)";
                if (sqlite3_prepare_v2(db, ins, -1, &stmt, NULL) != SQLITE_OK) {
                    localError = @"Could not prepare PosterBoard metadata insert";
                    ok = NO;
                } else {
                    sqlite3_bind_text(stmt, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 2, metadata.UTF8String, -1, SQLITE_TRANSIENT);
                    if (sqlite3_step(stmt) != SQLITE_DONE) {
                        localError = @"Could not insert PosterBoard metadata";
                        ok = NO;
                    }
                }
            }
        }
        sqlite3_finalize(stmt); stmt = NULL;
    }

    if (ok) {
        const char *sql =
            "DELETE FROM posterAttributes WHERE posterUUID=? "
            "AND roleId='PRPosterRoleLockScreen' AND attributeIdentifier='SELECTED'";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            localError = @"Could not prepare PosterBoard selected marker";
            ok = NO;
        } else {
            sqlite3_bind_text(stmt, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) != SQLITE_DONE) ok = NO;
        }
        sqlite3_finalize(stmt); stmt = NULL;
    }

    if (ok) {
        const char *sql =
            "INSERT INTO posterAttributes "
            "(posterUUID,roleId,attributeIdentifier,attributePayload) "
            "VALUES (?,'PRPosterRoleLockScreen','SELECTED',1)";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            localError = @"Could not prepare PosterBoard SELECTED insert";
            ok = NO;
        } else {
            sqlite3_bind_text(stmt, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) != SQLITE_DONE) {
                localError = [NSString stringWithFormat:@"PosterBoard SELECTED insert failed: %s", sqlite3_errmsg(db)];
                ok = NO;
            }
        }
        sqlite3_finalize(stmt); stmt = NULL;
    }

    if (ok) {
        const char *sql =
            "UPDATE posterRoleMembership SET roleSortKey=? "
            "WHERE posterUUID=? AND roleId='PRPosterRoleLockScreen'";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            localError = @"Could not prepare PosterBoard membership update";
            ok = NO;
        } else {
            nextSortKey++;
            sqlite3_bind_int64(stmt, 1, nextSortKey);
            sqlite3_bind_text(stmt, 2, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) != SQLITE_DONE) {
                localError = @"Could not update PosterBoard membership";
                ok = NO;
            } else if (sqlite3_changes(db) == 0) {
                sqlite3_finalize(stmt); stmt = NULL;
                const char *ins =
                    "INSERT INTO posterRoleMembership "
                    "(posterUUID,roleId,roleSortKey) VALUES "
                    "(?,'PRPosterRoleLockScreen',?)";
                if (sqlite3_prepare_v2(db, ins, -1, &stmt, NULL) != SQLITE_OK) {
                    localError = @"Could not prepare PosterBoard membership insert";
                    ok = NO;
                } else {
                    sqlite3_bind_text(stmt, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_int64(stmt, 2, nextSortKey);
                    if (sqlite3_step(stmt) != SQLITE_DONE) {
                        localError = @"Could not insert PosterBoard membership";
                        ok = NO;
                    }
                }
            }
        }
        sqlite3_finalize(stmt); stmt = NULL;
    }

    if (ok && ![self exec:db sql:"COMMIT;" error:&localError]) ok = NO;
    if (!ok) [self exec:db sql:"ROLLBACK;" error:nil];

    if (ok) {
        // Consolidate WAL into the main file and switch the delivered image
        // back to rollback-journal mode. AirCard later ships empty sidecars.
        [self exec:db sql:"PRAGMA wal_checkpoint(FULL);" error:&localError];
        if (![self exec:db sql:"PRAGMA journal_mode=DELETE;" error:&localError]) ok = NO;
        [self exec:db sql:"PRAGMA integrity_check;" error:&localError];
    }

    sqlite3_close(db);
    [fm removeItemAtPath:walPath error:nil];
    [fm removeItemAtPath:shmPath error:nil];

    if (!ok && error) *error = localError ?: @"PosterBoard database operation failed";
    return ok;
}

@end
