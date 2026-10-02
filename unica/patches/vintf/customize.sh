_LOG() { if $DEBUG; then LOGW "$1"; else ABORT "$1"; fi }

DECLARE_SENSOR_AIDL_HAL()
{
    local MANIFEST="$WORK_DIR/system/system/etc/vintf/manifest.xml"
    local AIDL_FQNAME='<fqname>ISensorManager/default</fqname>'
    local AWK_SCRIPT="$WORK_DIR/.vintf-sensorservice-aidl.awk"

    [ -f "$MANIFEST" ] || { _LOG "File not found: ${MANIFEST//$SRC_DIR\//}"; return 1; }

    if grep -qF "$AIDL_FQNAME" "$MANIFEST"; then
        LOG "- AIDL android.frameworks.sensorservice already declared in /system/system/etc/vintf/manifest.xml"
        return 0
    fi

    LOG "- Declaring AIDL android.frameworks.sensorservice in /system/system/etc/vintf/manifest.xml"

    cat > "$AWK_SCRIPT" <<-'AWK'
	!done && /<\/manifest>/ {
	    print "    <!-- Android 16 registers the framework SensorService through both the"
	    print "         legacy HIDL interface and its AIDL interface.  The service manager"
	    print "         rejects the AIDL registration unless it is declared here. -->"
	    print "    <hal format=\"aidl\">"
	    print "        <name>android.frameworks.sensorservice</name>"
	    print "        <fqname>ISensorManager/default</fqname>"
	    print "    </hal>"
	    done = 1
	}
	{ print }
AWK

    EVAL "awk -f \"$AWK_SCRIPT\" \"$MANIFEST\" > \"$MANIFEST.tmp\"" || exit 1

    grep -qF "$AIDL_FQNAME" "$MANIFEST.tmp" || { rm -f "$AWK_SCRIPT"; _LOG "Failed to declare AIDL android.frameworks.sensorservice"; return 1; }

    EVAL "mv -f \"$MANIFEST.tmp\" \"$MANIFEST\"" || exit 1
    rm -f "$AWK_SCRIPT"
}


if [ -f "$SRC_DIR/target/$TARGET_CODENAME/vintf/compatibility_matrix.device.xml" ]; then
    LOG "- Adding /system/system/etc/vintf/compatibility_matrix.device.xml"
    EVAL "cp -a \"$SRC_DIR/target/$TARGET_CODENAME/vintf/compatibility_matrix.device.xml\" \"$WORK_DIR/system/system/etc/vintf/compatibility_matrix.device.xml\""
elif [[ "$SOURCE_PLATFORM_SDK_VERSION" == "$TARGET_PLATFORM_SDK_VERSION" ]]; then
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/etc/vintf/compatibility_matrix.device.xml"
else
    _LOG "File not found: $SRC_DIR/target/$TARGET_CODENAME/vintf/compatibility_matrix.device.xml"
fi

if [ -f "$SRC_DIR/target/$TARGET_CODENAME/vintf/manifest.xml" ]; then
    LOG "- Adding /system/system/etc/vintf/manifest.xml"
    EVAL "cp -a \"$SRC_DIR/target/$TARGET_CODENAME/vintf/manifest.xml\" \"$WORK_DIR/system/system/etc/vintf/manifest.xml\""
elif [[ "$SOURCE_PLATFORM_SDK_VERSION" == "$TARGET_PLATFORM_SDK_VERSION" ]]; then
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/etc/vintf/manifest.xml"
fi

DECLARE_SENSOR_AIDL_HAL

unset -f _LOG DECLARE_SENSOR_AIDL_HAL
