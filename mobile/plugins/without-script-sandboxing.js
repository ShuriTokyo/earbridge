// Turns off Xcode's user script sandboxing in the generated iPhone project (mobile/ios), every
// time `expo prebuild` makes it. With it on, React Native's "Bundle React Native code and
// images" step can't write main.jsbundle into the build folder (EPERM), and the build fails
// at its very end.

const { withXcodeProject } = require('expo/config-plugins');

module.exports = function withoutScriptSandboxing(config) {
  return withXcodeProject(config, (config) => {
    const configurations = config.modResults.pbxXCBuildConfigurationSection();
    for (const configuration of Object.values(configurations)) {
      if (typeof configuration === 'object' && configuration.buildSettings) {
        configuration.buildSettings.ENABLE_USER_SCRIPT_SANDBOXING = 'NO';
      }
    }
    return config;
  });
};
