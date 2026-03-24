# SPDX-FileCopyrightText: Copyright (C) Electronic Cats
#
# SPDX-License-Identifier: MPL-2.0

from arduino.app_utils import *
from arduino.app_bricks.keyword_spotting import KeywordSpotting

spotter = KeywordSpotting()
spotter.on_detect("Warmer-light", lambda: Bridge.call("warmer_light"))
spotter.on_detect("Cooler-light", lambda: Bridge.call("cooler_light"))
spotter.on_detect("Dimmer", lambda: Bridge.call("dimmer"))
spotter.on_detect("Brighter", lambda: Bridge.call("brighter"))

App.run()
