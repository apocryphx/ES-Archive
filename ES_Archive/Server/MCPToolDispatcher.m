//
//  ToolsDispatcher MCPToolDispatcher.m
//  MCPServer
//
//  Created by Kolja Wawrowsky on 9/13/25.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPToolDispatcher.h"
#import "ESCoreDataStack.h"
#import <objc/runtime.h>

NSNotificationName const ESToolExecutedNotification = @"ESToolExecuted";

@implementation MCPToolDispatcher

+ (NSArray<NSString *> *)methodNames {
    return @[@"tools/list", @"tools/call"];
}

- (nonnull NSDictionary *)handleMethod:(nonnull NSString *)method
                                params:(nonnull NSDictionary *)params
                                 scope:(ESRequestScope *)scope
                                 error:(NSError *__autoreleasing  _Nullable * _Nullable)error {

    if ([method isEqualToString:@"tools/list"]) {
        return [self handleToolsList];
    }
    else if ([method isEqualToString:@"tools/call"]) {
        return [self handleToolsCallWithParams:params scope:scope error:error];
    }

    if (error) {
        *error = [NSError errorWithDomain:@"MCPError"
                                     code:-32601
                                 userInfo:@{NSLocalizedDescriptionKey: @"Method not found"}];
    }
    return @{};
}

- (NSDictionary *)handleToolsList {
    NSArray<Class> *toolClasses = [MCPToolDispatcher allToolClasses];
    NSMutableArray *tools = [NSMutableArray arrayWithCapacity:toolClasses.count];
    for (Class toolClass in toolClasses) {
        NSDictionary *toolJSON = [toolClass requestJSON];
        if (toolJSON) {
            [tools addObject:toolJSON];
        }
    }
    return @{@"tools": tools};
}

- (NSDictionary *)handleToolsCallWithParams:(NSDictionary *)params scope:(ESRequestScope *)scope error:(NSError **)error {
    NSString *toolName = params[@"name"];
    NSDictionary *arguments = params[@"arguments"];

    if (!toolName || ![toolName isKindOfClass:NSString.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError"
                                         code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing or invalid 'name' parameter"}];
        }
        return @{};
    }

    if (!arguments) {
        arguments = @{};
    }

    // Find tool class by matching requestJSON[@"name"]
    NSArray<Class> *toolClasses = [MCPToolDispatcher allToolClasses];
    Class toolClass = nil;

    for (Class candidate in toolClasses) {
        NSDictionary *toolJSON = [candidate requestJSON];
        if ([toolJSON[@"name"] isEqualToString:toolName]) {
            toolClass = candidate;
            break;
        }
    }

    if (!toolClass) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError"
                                         code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown tool: %@", toolName]}];
        }
        return @{};
    }

    // Get persistent store from ESCoreDataStack
    NSPersistentCloudKitContainer *store = [ESCoreDataStack shared].persistentContainer;

    // Execute tool. The per-request scope (persona identity, derived from the
    // listening port) is threaded in so the tool scopes its reads/mutations and
    // stamps writes to the connecting persona's author.
    NSError *executionError = nil;
    NSDictionary *result = [toolClass executeWithArguments:arguments
                                           persistentStore:store
                                                     scope:scope
                                                     error:&executionError];

    if (executionError) {
        // Notify with an error shape so the dashboard log can render "✗ error".
        NSDictionary *failureInfo = @{
            @"tool"      : toolName,
            @"arguments" : arguments ?: @{},
            @"result"    : @{
                @"status"  : @"error",
                @"message" : executionError.localizedDescription ?: @"Unknown error",
            },
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:ESToolExecutedNotification
                                                                object:nil
                                                              userInfo:failureInfo];
        });
        if (error) {
            *error = executionError;
        }
        return @{};
    }

    // Notify dashboard / activity log. The result and arguments are included
    // so the log can render "[time] tool  \"arg\"  shape" without re-parsing
    // the JSON envelope — see ViewController.m toolDidExecute:.
    NSDictionary *successInfo = @{
        @"tool"      : toolName,
        @"arguments" : arguments ?: @{},
        @"result"    : result    ?: @{},
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ESToolExecutedNotification
                                                            object:nil
                                                          userInfo:successInfo];
    });

    return @{@"content": @[
        @{
            @"type": @"text",
            @"text": result ? [self jsonStringFromDictionary:result] : @"{}"
        }
    ]};
}

- (NSString *)jsonStringFromDictionary:(NSDictionary *)dict {
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (error || !jsonData) {
        return @"{}";
    }
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

+ (NSArray<Class> *)allToolClasses {
    static NSArray<Class> *cached;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (!classes) { cached = @[]; return; }

        Protocol *protocol = @protocol(MCPTooling);
        NSMutableArray<Class> *result = [NSMutableArray array];

        for (unsigned int i = 0; i < count; i++) {
            if (class_conformsToProtocol(classes[i], protocol)) {
                [result addObject:classes[i]];
            }
        }
        free(classes);
        cached = result.copy;
    });
    return cached;
}

@end
