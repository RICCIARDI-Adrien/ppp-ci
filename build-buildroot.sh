#!/bin/sh

# Exit if any error occurs
set -e

PrintMessage()
{
	printf "\033[33m--> $1\033[0m\n"
}

# Check arguments
if [ $# -ne 3 ]
then
	echo "Usage : $0 buildroot_defconfig_name libc_name output_directory"
	echo "  buildroot_defconfig_name : see all available defconfigs here https://git.busybox.net/buildroot/tree/configs?h=2021.02.5"
	echo "  libc_name : must be \"glibc\", \"uclibc\" or \"musl\""
	echo "  output_directory : will contain the build directory and the final compressed artifacts"
	exit 1
fi
DEFCONFIG_NAME="$1"
LIBC_NAME="$2"
OUTPUT_DIRECTORY="$3"

# Create the build directory name
BUILD_DIRECTORY_NAME="buildroot-${DEFCONFIG_NAME}-${LIBC_NAME}"
BUILD_DIRECTORY_PATH=$(realpath "${OUTPUT_DIRECTORY}/${BUILD_DIRECTORY_NAME}")

PrintMessage "Removing previous build artifacts..."
rm -rf $BUILD_DIRECTORY_PATH

PrintMessage "Downloading Buildroot sources..."
git clone --depth=1 --branch=2021.02.5 https://github.com/buildroot/buildroot $BUILD_DIRECTORY_PATH

PrintMessage "Modifying the PPP package to use upstream PPP sources..."
PPP_PACKAGE_PATH="${BUILD_DIRECTORY_PATH}/package/pppd"
echo $PPP_PACKAGE_PATH
# Allow package to build when musl libc is selected
sed -i '/depends on !BR2_TOOLCHAIN_USES_MUSL/d' ${PPP_PACKAGE_PATH}/Config.in
# Upstream version always needs OpenSSL
sed -i '/select BR2_PACKAGE_OPENSSL/c\\select BR2_PACKAGE_OPENSSL' ${PPP_PACKAGE_PATH}/Config.in
# Do not check for package hash, so there is no need to compute it
rm ${PPP_PACKAGE_PATH}/pppd.hash
# Buildroot patch is already applied upstream
rm -f ${PPP_PACKAGE_PATH}/0001-pppd-Fix-bounds-check.patch
# Get package sources from head of master branch
LAST_COMMIT_HASH=$(curl -s -H "Accept: application/vnd.github.VERSION.sha" "https://api.github.com/repos/ppp-project/ppp/commits/master")
sed -i "/PPPD_VERSION =/c\\PPPD_VERSION = ${LAST_COMMIT_HASH}" ${PPP_PACKAGE_PATH}/pppd.mk
sed -i '/PPPD_SITE =/c\\PPPD_SITE = https://github.com/ppp-project/ppp' ${PPP_PACKAGE_PATH}/pppd.mk
sed -i '9iPPPD_SITE_METHOD = git' ${PPP_PACKAGE_PATH}/pppd.mk
# Tell Buildroot to run autoreconf.sh
sed -i '16iPPPD_AUTORECONF = YES' ${PPP_PACKAGE_PATH}/pppd.mk
# Filters feature needs libpcap
sed -i '17iPPPD_DEPENDENCIES = libpcap openssl' ${PPP_PACKAGE_PATH}/pppd.mk
# Enable verbose build commands and force OpenSSL directory, otherwise the host system one might be used instead of Buildroot one
sed -i '18iPPPD_CONF_OPTS = --disable-silent-rules --with-openssl="$(STAGING_DIR)/usr"' ${PPP_PACKAGE_PATH}/pppd.mk
# Do not install build artifacts to staging directory
sed -i 's/PPPD_INSTALL_STAGING = YES/PPPD_INSTALL_STAGING = NO/' ${PPP_PACKAGE_PATH}/pppd.mk
# Delete custom configuration tool, it is now automatically handled by Buildroot
sed -i '/PPPD_CONFIGURE_CMDS/,+4d' ${PPP_PACKAGE_PATH}/pppd.mk
# Delete custom build rule, it is now generated by Autotools
sed -i '/define PPPD_BUILD_CMDS/,+4d' ${PPP_PACKAGE_PATH}/pppd.mk
# Delete custom installation to target rule, it is now generated by Autotools
sed -i '/define PPPD_INSTALL_TARGET_CMDS/,+27d' ${PPP_PACKAGE_PATH}/pppd.mk
# Delete custom staging installation rule as PPP does not need to be installed to staging in this CI
sed -i '/define PPPD_INSTALL_STAGING_CMDS/,+3d' ${PPP_PACKAGE_PATH}/pppd.mk
# Tell Buildroot that this package uses Autotools
sed -i 's/$(eval $(generic-package))/$(eval $(autotools-package))/' ${PPP_PACKAGE_PATH}/pppd.mk

PrintMessage "Enabling PPP build in Buildroot configuration..."
# Enable all Buildroot PPP options as everything is built by upstream build system
echo "BR2_PACKAGE_PPPD=y" >> ${BUILD_DIRECTORY_PATH}/configs/${DEFCONFIG_NAME}
echo "BR2_PACKAGE_PPPD_FILTER=y" >> ${BUILD_DIRECTORY_PATH}/configs/${DEFCONFIG_NAME}
echo "BR2_PACKAGE_PPPD_RADIUS=y" >> ${BUILD_DIRECTORY_PATH}/configs/${DEFCONFIG_NAME}
echo "BR2_PACKAGE_PPPD_OVERWRITE_RESOLV_CONF=y" >> ${BUILD_DIRECTORY_PATH}/configs/${DEFCONFIG_NAME}

PrintMessage "Selecting the ${LIBC_NAME} libc..."
case $LIBC_NAME in
	"glibc")
		echo "BR2_TOOLCHAIN_BUILDROOT_GLIBC=y" >> ${BUILD_DIRECTORY_PATH}/configs/${DEFCONFIG_NAME}
		;;
	"uclibc")
		echo "BR2_TOOLCHAIN_BUILDROOT_UCLIBC=y" >> ${BUILD_DIRECTORY_PATH}/configs/${DEFCONFIG_NAME}
		;;
	"musl")
		echo "BR2_TOOLCHAIN_BUILDROOT_MUSL=y" >> ${BUILD_DIRECTORY_PATH}/configs/${DEFCONFIG_NAME}
		;;
	*)
		echo "Unknown libc, please specify \"glibc\", \"uclibc\" or \"musl\"."
		exit 1
		;;
esac

PrintMessage "Generating Buildroot configuration..."
cd $BUILD_DIRECTORY_PATH
make $DEFCONFIG_NAME

PrintMessage "Building..."
make
