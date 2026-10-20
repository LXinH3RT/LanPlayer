//
//  Runner-Bridging-Header.h
//  LanPlayer (macOS)
//
//  Exposes the C playback core to Swift.  Set this file as
//  "Objective-C Bridging Header" in the Runner target build settings
//  (already done in Runner.xcodeproj/project.pbxproj).
//
#import <Foundation/Foundation.h>

#include "lanplayer/lp_player.h"
#include "lanplayer/lp_source.h"
#include "lanplayer/lp_log.h"
#include "lanplayer/lp_types.h"
