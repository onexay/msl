#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Notarize and staple a Developer ID signed release (not runnable with ad-hoc signing).
#   xcrun notarytool store-credentials msl-notary --apple-id … --team-id … --password <app-specific>
#   MSL_NOTARY_PROFILE=msl-notary scripts/notarize.sh dist/msl-<version>.pkg
set -eu
PKG=$1
: "${MSL_NOTARY_PROFILE:?set MSL_NOTARY_PROFILE to a notarytool keychain profile}"
pkgutil --check-signature "$PKG" | grep -q "Developer ID Installer" || { echo "$PKG is not signed with a Developer ID Installer identity"; exit 1; }
xcrun notarytool submit "$PKG" --keychain-profile "$MSL_NOTARY_PROFILE" --wait
xcrun stapler staple "$PKG"
spctl --assess --type install -vv "$PKG"
