# Remove the legacy WSM userspace stack. It cannot provide a valid trust
# result on an unlocked device and only adds another failing HAL path.
DELETE_FROM_WORK_DIR "system" "system/etc/public.libraries-wsm.samsung.txt"
DELETE_FROM_WORK_DIR "system" "system/lib/libhal.wsm.samsung.so"
DELETE_FROM_WORK_DIR "system" "system/lib/vendor.samsung.hardware.security.wsm.service-V1-ndk.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libhal.wsm.samsung.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/vendor.samsung.hardware.security.wsm.service-V1-ndk.so"

# Install the static KnoxPatch dispatcher into framework.jar. The dispatcher
# scopes app-facing spoofing to the same packages as upstream KnoxPatch.
DECODE_APK "system" "system/framework/framework.jar"
mkdir -p "$APKTOOL_DIR/system/framework/framework.jar/smali_classes6/io/mesalabs/unica"
cp -f "$MODPATH/framework.jar/KnoxPatchHooks.smali" \
    "$APKTOOL_DIR/system/framework/framework.jar/smali_classes6/io/mesalabs/unica/KnoxPatchHooks.smali"

# Record the process package name when an application is created. This reads
# Context.getPackageName(), which already exists in classes.dex, so no new
# method_id is introduced: framework.jar's classes.dex is exactly full at the
# 65536-entry dex limit and cannot take any extra method reference.
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali/android/app/Instrumentation.smali" "replace" \
    'newApplication(Ljava/lang/Class;Landroid/content/Context;)Landroid/app/Application;' \
    'return-object p0' \
    '    invoke-virtual {p1}, Landroid/content/Context;->getPackageName()Ljava/lang/String;\n\n    move-result-object p1\n\n    sput-object p1, Lio/mesalabs/unica/KnoxPatchHooks;->sPackageName:Ljava/lang/String;\n\n    return-object p0'
# This overload already calls Context.getPackageName() into v0 to feed
# Instrumentation.getFactory(), so we store v0 from that existing instruction
# instead of guessing which parameter holds the Context: the descriptor lists
# three parameters while the body passes p3 to Application.attach().
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali/android/app/Instrumentation.smali" "replace" \
    'newApplication(Ljava/lang/ClassLoader;Ljava/lang/String;Landroid/content/Context;)Landroid/app/Application;' \
    'invoke-direct {p0, v0}, Landroid/app/Instrumentation;->getFactory(Ljava/lang/String;)Landroid/app/AppComponentFactory;' \
    '    sput-object v0, Lio/mesalabs/unica/KnoxPatchHooks;->sPackageName:Ljava/lang/String;\n\n    invoke-direct {p0, v0}, Landroid/app/Instrumentation;->getFactory(Ljava/lang/String;)Landroid/app/AppComponentFactory;'

_KP_INSTR="$APKTOOL_DIR/system/framework/framework.jar/smali/android/app/Instrumentation.smali"
for _KP_SIG in \
    'newApplication(Ljava/lang/Class;Landroid/content/Context;)Landroid/app/Application;' \
    'newApplication(Ljava/lang/ClassLoader;Ljava/lang/String;Landroid/content/Context;)Landroid/app/Application;'; do
    _KP_COUNT="$(awk -v FN="$_KP_SIG" '
        /^\.method/ && index($0, FN) { inside = 1 }
        inside && /Context;->getPackageName\(\)Ljava\/lang\/String;/ { n++ }
        inside && /^\.end method/ { inside = 0 }
        END { print n + 0 }
    ' "$_KP_INSTR")"
    if [ "$_KP_COUNT" != "1" ]; then
        LOG "! ERROR: Instrumentation.newApplication has $_KP_COUNT getPackageName() calls, expected 1"
        return 1
    fi

    _KP_CTX="$(awk -v FN="$_KP_SIG" '
        /^\.method/ && index($0, FN) { inside = 1 }
        inside && /Application;->attach\(Landroid\/content\/Context;\)V/ {
            sub(/.*\{/, "", $0); sub(/\}.*/, "", $0)
            n = split($0, a, /[ ,]+/); print a[n]; exit
        }
        inside && /^\.end method/ { inside = 0 }
    ' "$_KP_INSTR")"
    _KP_GPN="$(awk -v FN="$_KP_SIG" '
        /^\.method/ && index($0, FN) { inside = 1 }
        inside && /Context;->getPackageName\(\)Ljava\/lang\/String;/ {
            sub(/.*\{/, "", $0); sub(/\}.*/, "", $0)
            n = split($0, a, /[ ,]+/); print a[n]; exit
        }
        inside && /^\.end method/ { inside = 0 }
    ' "$_KP_INSTR")"
    if [ -z "$_KP_CTX" ] || [ "$_KP_CTX" != "$_KP_GPN" ]; then
        LOG "! ERROR: Instrumentation.newApplication calls getPackageName() on '$_KP_GPN' but attach() takes '$_KP_CTX'"
        return 1
    fi

    _KP_MR="$(awk -v FN="$_KP_SIG" '
        /^\.method/ && index($0, FN) { inside = 1 }
        inside && /Context;->getPackageName\(\)Ljava\/lang\/String;/ && !seen { seen = 1 }
        inside && seen && !got && /move-result-object / { print $2; got = 1; exit }
        inside && /^\.end method/ { inside = 0 }
    ' "$_KP_INSTR")"
    _KP_SP="$(awk -v FN="$_KP_SIG" '
        /^\.method/ && index($0, FN) { inside = 1 }
        inside && /sput-object .*KnoxPatchHooks;->sPackageName/ { gsub(/,/, "", $2); print $2; exit }
        inside && /^\.end method/ { inside = 0 }
    ' "$_KP_INSTR")"
    if [ -z "$_KP_SP" ] || [ "$_KP_MR" != "$_KP_SP" ]; then
        LOG "! ERROR: Instrumentation.newApplication stored '$_KP_SP' but getPackageName() fills '$_KP_MR'"
        return 1
    fi
done

# Members of KnoxPatchHooks are called from other classes (Instrumentation
# writes the package name, SystemProperties and EnterpriseDeviceManager call
# in). A non-public one only fails at runtime with IllegalAccessError, so
# check the declarations before building.
_KP_HOOKS="$APKTOOL_DIR/system/framework/framework.jar/smali_classes6/io/mesalabs/unica/KnoxPatchHooks.smali"
for _KP_MEM in sPackageName onSystemPropertiesGet shouldDisableKnoxSdk; do
    if ! grep -qE "^\.(field|method) public .*[ ]${_KP_MEM}" "$_KP_HOOKS"; then
        LOG "! ERROR: KnoxPatchHooks.${_KP_MEM} is not public but is accessed from another class"
        return 1
    fi
done

# Intercept both SystemProperties overloads. SemSystemProperties delegates to
# these methods on One UI 9, so this covers Auto Blocker, Secure Folder,
# Secure Wi-Fi, SmartThings, FMM and the system-server ASKS check.
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali_classes3/android/os/SystemProperties.smali" "replace" \
    'get(Ljava/lang/String;)Ljava/lang/String;' \
    '.locals 0' '.locals 1'
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali_classes3/android/os/SystemProperties.smali" "replace" \
    'get(Ljava/lang/String;)Ljava/lang/String;' \
    'invoke-static {p0}, Landroid/os/SystemProperties;->native_get(Ljava/lang/String;)Ljava/lang/String;' \
    '    invoke-static {p0}, Lio/mesalabs/unica/KnoxPatchHooks;->onSystemPropertiesGet(Ljava/lang/String;)Ljava/lang/String;\n\n    move-result-object v0\n\n    if-eqz v0, :unica_knoxpatch_get\n\n    return-object v0\n\n    :unica_knoxpatch_get\n    invoke-static {p0}, Landroid/os/SystemProperties;->native_get(Ljava/lang/String;)Ljava/lang/String;'
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali_classes3/android/os/SystemProperties.smali" "replace" \
    'get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;' \
    '.locals 0' '.locals 1'
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali_classes3/android/os/SystemProperties.smali" "replace" \
    'get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;' \
    'invoke-static {p0, p1}, Landroid/os/SystemProperties;->native_get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;' \
    '    invoke-static {p0, p1}, Lio/mesalabs/unica/KnoxPatchHooks;->onSystemPropertiesGet(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;\n\n    move-result-object v0\n\n    if-eqz v0, :unica_knoxpatch_get_default\n\n    return-object v0\n\n    :unica_knoxpatch_get_default\n    invoke-static {p0, p1}, Landroid/os/SystemProperties;->native_get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;'

# Samsung Health expects Knox SDK to report unsupported only in its process.
SMALI_PATCH "system" "system/framework/knoxsdk.jar" \
    "smali/com/samsung/android/knox/EnterpriseDeviceManager.smali" "replace" \
    'getAPILevel()I' \
    'invoke-static {}, Lcom/samsung/android/knox/EdmUtils;->getAPILevelForInternal()I' \
    '    invoke-static {}, Lio/mesalabs/unica/KnoxPatchHooks;->shouldDisableKnoxSdk()Z\n\n    move-result v0\n\n    if-eqz v0, :unica_knoxpatch_edm\n\n    const/4 v0, -0x1\n\n    return v0\n\n    :unica_knoxpatch_edm\n    invoke-static {}, Lcom/samsung/android/knox/EdmUtils;->getAPILevelForInternal()I'

# SAK/ICD: make verifiable integrity available through both copies used by
# One UI 9. The services.jar copy accesses the field directly; the public
# samsungkeystoreutils.jar copy uses the accessor.
SMALI_PATCH "system" "system/framework/samsungkeystoreutils.jar" \
    "smali/com/samsung/android/security/keystore/AttestParameterSpec.smali" "return" \
    'isVerifiableIntegrity()Z' 'true'
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali_classes2/com/samsung/android/security/keystore/AttestationUtils.smali" "replace" \
    'generateKeyPair(Lcom/samsung/android/security/keystore/AttestParameterSpec;)Ljava/security/KeyPair;' \
    'iget-object v0, p1, Lcom/samsung/android/security/keystore/AttestParameterSpec;->mSpec:Landroid/security/keystore/KeyGenParameterSpec;' \
    '    const/4 v0, 0x1\n\n    iput-boolean v0, p1, Lcom/samsung/android/security/keystore/AttestParameterSpec;->mVerifiableIntegrity:Z\n\n    iget-object v0, p1, Lcom/samsung/android/security/keystore/AttestParameterSpec;->mSpec:Landroid/security/keystore/KeyGenParameterSpec;'

# Secure Folder/work-profile trust decisions moved behind DAR binder methods.
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali/com/android/server/knox/dar/DarManagerService.smali" "return" \
    'checkDeviceIntegrity([Ljava/security/cert/Certificate;)Z' 'true'
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali/com/android/server/knox/dar/DarManagerService.smali" "return" \
    'isDeviceRootKeyInstalled()Z' 'true'
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali/com/android/server/knox/dar/DarManagerService.smali" "return" \
    'isKnoxKeyInstallable()Z' 'true'
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali/com/android/server/StorageManagerService.smali" "return" \
    'isRootedDevice()Z' 'false'

# One UI 9 replaced KnoxGuardSeService with KnoxGuard30Service. Match the
# upstream KnoxPatch behavior at the new constructor boundary: throw after
# the Binder stub is initialised so SystemServer's existing catch path skips
# registration without entering the missing KG30 vendor AIDL path.
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali_classes2/com/samsung/android/knoxguard30/service/KnoxGuard30Service.smali" "replace" \
    '<init>(Landroid/content/Context;)V' \
    'sput-object p1, Lcom/samsung/android/knoxguard30/service/KnoxGuard30Service;->mContext:Landroid/content/Context;' \
    '    new-instance v0, Ljava/lang/UnsupportedOperationException;\n\n    const-string v1, "KnoxGuard 3.0 is unsupported on this port"\n\n    invoke-direct {v0, v1}, Ljava/lang/UnsupportedOperationException;-><init>(Ljava/lang/String;)V\n\n    throw v0'

# Knox Matrix 3.x verifies parsed attestation objects through FabricCertUtil.
# Patch the decision points as well as the value-object accessors used by its
# other trust-chain implementations. Do not download a moving Galaxy Store
# build during ROM compilation.
if [ -f "$WORK_DIR/system/system/priv-app/KmxService/KmxService.apk" ]; then
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/fabrickeystore/keystore/cert/FabricCertUtil.smali" "return" \
        'checkIntegrityStatus(Lcom/samsung/android/kmxservice/fabrickeystore/keystore/cert/IntegrityStatus;)Z' 'true'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/fabrickeystore/keystore/cert/FabricCertUtil.smali" "return" \
        'checkRootOfTrust(Lcom/samsung/android/kmxservice/fabrickeystore/keystore/cert/RootOfTrust;)Z' 'true'

    for ROOT_OF_TRUST in \
        "common/util/RootOfTrust" \
        "fabrickeystore/keystore/cert/RootOfTrust" \
        "sdk/trustchain/util/RootOfTrust"
    do
        SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
            "smali_classes2/com/samsung/android/kmxservice/$ROOT_OF_TRUST.smali" "return" \
            'getVerifiedBootState()I' '0'
        SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
            "smali_classes2/com/samsung/android/kmxservice/$ROOT_OF_TRUST.smali" "return" \
            'isDeviceLocked()Z' 'true'
    done

    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/common/util/IntegrityStatus.smali" "return" \
        'getStatus()I' '0'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/common/util/IntegrityStatus.smali" "return" \
        'isNormal()Z' 'true'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/fabrickeystore/keystore/cert/IntegrityStatus.smali" "return" \
        'isNormal()Z' 'true'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/sdk/trustchain/util/IntegrityStatus.smali" "return" \
        'getStatus()I' '0'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/sdk/trustchain/util/IntegrityStatus.smali" "return" \
        'isNormal()Z' 'true'
fi
