#import "AppDelegate.h"
#import <ScriptingBridge/ScriptingBridge.h>
#import <objc/runtime.h>

NSString * const TerminalNotifierBundleID = @"org.gaborcsardi.notifier";
NSString * const NotificationCenterUIBundleID = @"com.apple.notificationcenterui";

#define contains(str1, str2) ([str1 rangeOfString: str2 ].location != NSNotFound)

NSString *_fakeBundleIdentifier = nil;
NSUserNotification *currentNotification = nil;

@implementation NSBundle (FakeBundleIdentifier)

// Overriding bundleIdentifier works, but overriding NSUserNotificationAlertStyle does not work.

- (NSString *)__bundleIdentifier;
{
  if (self == [NSBundle mainBundle]) {
    return _fakeBundleIdentifier ? _fakeBundleIdentifier : TerminalNotifierBundleID;
  } else {
    return [self __bundleIdentifier];
  }
}

@end

static BOOL
InstallFakeBundleIdentifierHook()
{
  Class class = objc_getClass("NSBundle");
  if (class) {
    method_exchangeImplementations(class_getInstanceMethod(class, @selector(bundleIdentifier)),
                                   class_getInstanceMethod(class, @selector(__bundleIdentifier)));
    return YES;
  }
  return NO;
}

@implementation NSUserDefaults (SubscriptAndUnescape)
- (id)objectForKeyedSubscript:(id)key;
{
  id obj = [self objectForKey:key];
  if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj hasPrefix:@"\\"]) {
    obj = [(NSString *)obj substringFromIndex:1];
  }
  return obj;
}
@end


@implementation AppDelegate

+(void)initializeUserDefaults
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDictionary *appDefaults;
  appDefaults = @{@"sender": @"com.apple.Terminal"};
  [defaults registerDefaults:appDefaults];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
{
  NSUserNotification *userNotification = notification.userInfo[NSApplicationLaunchUserNotificationKey];
  if (userNotification) {
    [self userActivatedNotification:userNotification];

  } else {

    NSArray *runningProcesses = [[[NSWorkspace sharedWorkspace] runningApplications] valueForKey:@"bundleIdentifier"];
    if ([runningProcesses indexOfObject:NotificationCenterUIBundleID] == NSNotFound) {
      NSLog(@"[!] Unable to post a notification for the current user (%@), as it has no running NotificationCenter instance.", NSUserName());
      exit(1);
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSString *subtitle = defaults[@"subtitle"];
    NSString *message  = defaults[@"message"];
    NSString *remove   = defaults[@"remove"];
    NSString *list     = defaults[@"list"];
    NSString *sound    = defaults[@"sound"];

    // If there is no message and data is piped to the application, use that
    // instead.
    if (message == nil && !isatty(STDIN_FILENO)) {
      NSData *inputData = [NSData dataWithData:[[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile]];
      message = [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
    }

    if (message == nil && remove == nil && list == nil) {
      exit(1);
    }

    if (list) {
      [self listNotificationWithGroupID:list];
      exit(0);
    }

    // Install the fake bundle ID hook so we can fake the sender. This also
    // needs to be done to be able to remove a message.
    if (defaults[@"sender"]) {
      @autoreleasepool {
        if (InstallFakeBundleIdentifierHook()) {
          _fakeBundleIdentifier = defaults[@"sender"];
        }
      }
    }

    if (remove) {
      [self removeNotificationWithGroupID:remove];
      if (message == nil || ([message length] == 0)) {
          exit(0);
      }
    }

    if (message) {
      NSMutableDictionary *options = [NSMutableDictionary dictionary];
      if (defaults[@"activate"])      options[@"bundleID"]      = defaults[@"activate"];
      if (defaults[@"group"])         options[@"groupID"]       = defaults[@"group"];
      if (defaults[@"execute"])       options[@"command"]       = defaults[@"execute"];
      if (defaults[@"appIcon"])       options[@"appIcon"]       = defaults[@"appIcon"];
      if (defaults[@"contentImage"])  options[@"contentImage"]  = defaults[@"contentImage"];
      if (defaults[@"closeLabel"])    options[@"closeLabel"]    = defaults[@"closeLabel"];
      if (defaults[@"dropdownLabel"]) options[@"dropdownLabel"] = defaults[@"dropdownLabel"];
      if (defaults[@"actions"])       options[@"actions"]       = defaults[@"actions"];

      if([[[NSProcessInfo processInfo] arguments] containsObject:@"-reply"] == true) {
        options[@"reply"] = @"Reply";
        if (defaults[@"reply"]) options[@"reply"] = defaults[@"reply"];
      }

      options[@"output"] = @"outputEvent";
      if([[[NSProcessInfo processInfo] arguments] containsObject:@"-json"] == true) {
        options[@"output"] = @"json";
      }

      options[@"uuid"] = [NSString stringWithFormat:@"%ld", self.hash];
      options[@"timeout"] = defaults[@"timeout"] ? defaults[@"timeout"] : @"0";

      if (options[@"reply"] || defaults[@"timeout"] || defaults[@"actions"] || defaults[@"execute"] || defaults[@"open"] || options[@"bundleID"]) options[@"waitForResponse"] = @YES;

      if (defaults[@"open"]) {
        NSURL *url = [NSURL URLWithString:defaults[@"open"]];
        if ((url && url.scheme && url.host) || [url isFileURL]) {
          options[@"open"] = defaults[@"open"];
        }else{
          NSLog(@"'%@' is not a valid URI.", defaults[@"open"]);
          exit(1);
        }
      }

      options[@"uuid"] = [NSString stringWithFormat:@"%ld", self.hash];

      [self deliverNotificationWithTitle:defaults[@"title"] ?: @"Terminal"
                                subtitle:subtitle
                                 message:message
                                 options:options
                                   sound:sound];
    }
  }
}

- (NSImage*)getImageFromURL:(NSString *) url;
{
  NSURL *imageURL = [NSURL URLWithString:url];
  if([[imageURL scheme] length] == 0){
    // Prefix 'file://' if no scheme
    imageURL = [NSURL fileURLWithPath:url];
  }
  return [[NSImage alloc] initWithContentsOfURL:imageURL];
}

- (void)deliverNotificationWithTitle:(NSString *)title
                            subtitle:(NSString *)subtitle
                             message:(NSString *)message
                             options:(NSDictionary *)options
                               sound:(NSString *)sound;
{
  // First remove earlier notification with the same group ID.
  if (options[@"groupID"]) [self removeNotificationWithGroupID:options[@"groupID"]];

  NSUserNotification *userNotification = [NSUserNotification new];
  userNotification.title = title;
  userNotification.subtitle = subtitle;
  userNotification.informativeText = message;
  userNotification.userInfo = options;

  if(options[@"appIcon"]){
    // replacement app icon
    [userNotification setValue:[self getImageFromURL:options[@"appIcon"]] forKey:@"_identityImage"];
    [userNotification setValue:@(false) forKey:@"_identityImageHasBorder"];
  }
  if(options[@"contentImage"]){
    // content image
    userNotification.contentImage = [self getImageFromURL:options[@"contentImage"]];
  }
  // Actions
  if (options[@"actions"]){
    [userNotification setValue:@YES forKey:@"_showsButtons"];
    NSArray *myActions = [options[@"actions"] componentsSeparatedByString:@","];
    if (myActions.count > 1) {
      [userNotification setValue:@YES forKey:@"_alwaysShowAlternateActionMenu"];
      [userNotification setValue:myActions forKey:@"_alternateActionButtonTitles"];

      //Main Actions Title
      if(options[@"dropdownLabel"]){
        userNotification.actionButtonTitle = options[@"dropdownLabel"];
        userNotification.hasActionButton = true;
      }
    }else{
      userNotification.actionButtonTitle = options[@"actions"];
    }
  }else if (options[@"reply"]) {
    [userNotification setValue:@YES forKey:@"_showsButtons"];
    userNotification.hasReplyButton = 1;
    userNotification.responsePlaceholder = options[@"reply"];
  }

  // Close button
  if(options[@"closeLabel"]){
    userNotification.otherButtonTitle = options[@"closeLabel"];
  }

  if (sound != nil) {
    userNotification.soundName = [sound isEqualToString: @"default"] ? NSUserNotificationDefaultSoundName : sound;
  }

  NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];
  center.delegate = self;
  [center deliverNotification:userNotification];
}

- (void)removeNotificationWithGroupID:(NSString *)groupID;
{
  NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];
  for (NSUserNotification *userNotification in center.deliveredNotifications) {
    if ([@"ALL" isEqualToString:groupID] || [userNotification.userInfo[@"groupID"] isEqualToString:groupID]) {
      [center removeDeliveredNotification:userNotification];
    }
  }
}

- (void)userActivatedNotification:(NSUserNotification *)userNotification;
{
  [[NSUserNotificationCenter defaultUserNotificationCenter] removeDeliveredNotification:userNotification];

  NSString *bundleID = userNotification.userInfo[@"bundleID"];
  NSString *command  = userNotification.userInfo[@"command"];
  NSString *open     = userNotification.userInfo[@"open"];

  if (bundleID) [self activateAppWithBundleID:bundleID];
  if (command)  [self executeShellCommand:command];
  if (open)     [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:open]];
}

- (BOOL)activateAppWithBundleID:(NSString *)bundleID;
{
  id app = [SBApplication applicationWithBundleIdentifier:bundleID];
  if (app) {
    [app activate];
    return YES;

  } else {
    NSLog(@"Unable to find an application with the specified bundle indentifier.");
    return NO;
  }
}

- (BOOL)executeShellCommand:(NSString *)command;
{
  NSPipe *pipe = [NSPipe pipe];
  NSFileHandle *fileHandle = [pipe fileHandleForReading];

  NSTask *task = [NSTask new];
  task.launchPath = @"/bin/sh";
  task.arguments = @[@"-c", command];
  task.standardOutput = pipe;
  task.standardError = pipe;
  [task launch];

  NSData *data = nil;
  NSMutableData *accumulatedData = [NSMutableData data];
  while ((data = [fileHandle availableData]) && [data length]) {
    [accumulatedData appendData:data];
  }

  [task waitUntilExit];
  NSLog(@"command output:\n%@", [[NSString alloc] initWithData:accumulatedData encoding:NSUTF8StringEncoding]);
  return [task terminationStatus] == 0;
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center
     shouldPresentNotification:(NSUserNotification *)notification;
{
  return YES;
}

// Once the notification is delivered we can exit. (Only if no actions or reply)
- (void)userNotificationCenter:(NSUserNotificationCenter *)center
        didDeliverNotification:(NSUserNotification *)userNotification;
{
  if (!userNotification.userInfo[@"waitForResponse"]) exit(0);

  currentNotification = userNotification;

  dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   __block BOOL notificationStillPresent;
                   do {
                     @autoreleasepool {
                       notificationStillPresent = NO;
                       for (NSUserNotification *nox in [[NSUserNotificationCenter defaultUserNotificationCenter] deliveredNotifications]) {
                         if ([nox.userInfo[@"uuid"]  isEqualToString:[NSString stringWithFormat:@"%ld", self.hash] ]) notificationStillPresent = YES;
                       }
                       if (notificationStillPresent) [NSThread sleepForTimeInterval:0.20f];
                     }
                   } while (notificationStillPresent);

                   dispatch_async(dispatch_get_main_queue(), ^{
                       NSDictionary *udict = @{@"activationType" : @"closed", @"activationValue" : userNotification.otherButtonTitle};
                       [self Quit:udict notification:userNotification];
                       exit(0);
                     });
                 });

  if ([userNotification.userInfo[@"timeout"] integerValue] > 0){
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                   ^{
                     [NSThread sleepForTimeInterval:[userNotification.userInfo[@"timeout"] integerValue]];
                     [center removeDeliveredNotification:currentNotification];
                     [center removeDeliveredNotification:userNotification];
                     NSDictionary *udict = @{@"activationType" : @"timeout"};
                     [self Quit:udict notification:userNotification];
                     exit(0);
                   });
  }
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center
       didActivateNotification:(NSUserNotification *)notification {

  if ([notification.userInfo[@"uuid"]  isNotEqualTo:[NSString stringWithFormat:@"%ld", self.hash] ]) {
    return;
  };

  unsigned long long additionalActionIndex = ULLONG_MAX;

  NSString *ActionsClicked = @"";
  switch (notification.activationType) {
  case NSUserNotificationActivationTypeAdditionalActionClicked:
  case NSUserNotificationActivationTypeActionButtonClicked:
    if ([[(NSObject*)notification valueForKey:@"_alternateActionButtonTitles"] count] > 1){
      NSNumber *alternateActionIndex = [(NSObject*)notification valueForKey:@"_alternateActionIndex"];
      additionalActionIndex = [alternateActionIndex unsignedLongLongValue];
      ActionsClicked = [(NSObject*)notification valueForKey:@"_alternateActionButtonTitles"][additionalActionIndex];

      NSDictionary *udict = @{@"activationType" : @"actionClicked", @"activationValue" : ActionsClicked, @"activationValueIndex" :[NSString stringWithFormat:@"%llu", additionalActionIndex]};
      [self Quit:udict notification:notification];
    }else{
      NSDictionary *udict = @{@"activationType" : @"actionClicked", @"activationValue" : notification.actionButtonTitle};
      [self Quit:udict notification:notification];
    }
    break;

  case NSUserNotificationActivationTypeContentsClicked:
    [self userActivatedNotification:notification];
    [self Quit:@{@"activationType" : @"contentsClicked"} notification:notification];
    break;

  case NSUserNotificationActivationTypeReplied:
    [self Quit:@{@"activationType" : @"replied",@"activationValue":notification.response.string} notification:notification];
    break;
  case NSUserNotificationActivationTypeNone:
  default:
    [self Quit:@{@"activationType" : @"none"} notification:notification];
    break;
  }

  [center removeDeliveredNotification:notification];
  [center removeDeliveredNotification:currentNotification];
  exit(0);
}

- (BOOL)Quit:(NSDictionary *)udict notification:(NSUserNotification *)notification;
{
  if ([notification.userInfo[@"output"] isEqualToString:@"outputEvent"]) {
    if ([udict[@"activationType"] isEqualToString:@"closed"]) {
      if ([udict[@"activationValue"] isEqualToString:@""]) {
        NSLog(@"@CLOSED");
      }else{
        NSLog(@"@%s", [udict[@"activationValue"] UTF8String]);
      }
    } else  if ([udict[@"activationType"] isEqualToString:@"timeout"]) {
      NSLog(@"@TIMEOUT");
    } else  if ([udict[@"activationType"] isEqualToString:@"contentsClicked"]) {
      NSLog(@"@CONTENTCLICKED");
    } else{
      if ([udict[@"activationValue"] isEqualToString:@""]) {
        NSLog(@"@ACTIONCLICKED");
      }else{
        NSLog(@"@%s", [udict[@"activationValue"] UTF8String]);
      }
    }

    return 1;
  }

  NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
  dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";

  // Dictionary with several key/value pairs and the above array of arrays
  NSMutableDictionary *dict = [NSMutableDictionary dictionary];
  [dict addEntriesFromDictionary:udict];
  [dict setValue:[dateFormatter stringFromDate:notification.actualDeliveryDate] forKey:@"deliveredAt"];
  [dict setValue:[dateFormatter stringFromDate:[NSDate new]] forKey:@"activationAt"];

  NSError *error = nil;
  NSData *json;

  // Dictionary convertable to JSON ?
  if ([NSJSONSerialization isValidJSONObject:dict])
    {
      // Serialize the dictionary
      json = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];

      // If no errors, let's view the JSON
      if (json != nil && error == nil)
        {
          NSString *jsonString = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
          printf("%s", [jsonString cStringUsingEncoding:NSUTF8StringEncoding]);
        }
    }

  return 1;
}

- (void)listNotificationWithGroupID:(NSString *)listGroupID;
{
  NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];

  NSMutableArray *lines = [NSMutableArray array];
  for (NSUserNotification *userNotification in center.deliveredNotifications) {
    NSString *deliveredgroupID = userNotification.userInfo[@"groupID"];
    NSString *title            = userNotification.title;
    NSString *subtitle         = userNotification.subtitle;
    NSString *message          = userNotification.informativeText;
    NSString *deliveredAt      = [userNotification.actualDeliveryDate description];

    if ([@"ALL" isEqualToString:listGroupID] || [deliveredgroupID isEqualToString:listGroupID]) {
      NSMutableDictionary *dict = [NSMutableDictionary dictionary];
      [dict setValue:deliveredgroupID forKey:@"GroupID"];
      [dict setValue:title forKey:@"Title"];
      [dict setValue:subtitle forKey:@"subtitle"];
      [dict setValue:message forKey:@"message"];
      [dict setValue:deliveredAt forKey:@"deliveredAt"];
      [lines addObject:dict];
    }
  }

  if (lines.count > 0) {
    NSData *json;
    NSError *error = nil;
    // Dictionary convertable to JSON ?
    if ([NSJSONSerialization isValidJSONObject:lines])
      {
        // Serialize the dictionary
        json = [NSJSONSerialization dataWithJSONObject:lines options:NSJSONWritingPrettyPrinted error:&error];

        // If no errors, let's view the JSON
        if (json != nil && error == nil)
          {
            NSString *jsonString = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
            printf("%s", [jsonString cStringUsingEncoding:NSUTF8StringEncoding]);
          }
      }

  }
}

- (void) bye; {
  //Look for the notification sent, remove it when found
  NSString *UUID = currentNotification.userInfo[@"uuid"] ;
  for (NSUserNotification *nox in [[NSUserNotificationCenter defaultUserNotificationCenter] deliveredNotifications]) {
    if ([nox.userInfo[@"uuid"] isEqualToString:UUID ]){
      [[NSUserNotificationCenter defaultUserNotificationCenter] removeDeliveredNotification:nox] ;
      [[NSUserNotificationCenter defaultUserNotificationCenter] removeDeliveredNotification:nox] ;
    }
  }
}

@end
