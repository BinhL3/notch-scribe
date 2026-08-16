import React from "react";
import { useTranslation } from "react-i18next";
import { Dropdown } from "../ui/Dropdown";
import { SettingContainer } from "../ui/SettingContainer";
import { ResetButton } from "../ui/ResetButton";
import { useSettings } from "../../hooks/useSettings";

interface MicrophoneSelectorProps {
  descriptionMode?: "inline" | "tooltip";
  grouped?: boolean;
}

/// Microphone preference is a ranking, not a single pick: the first one that
/// is connected wins, so a docked USB mic and the built-in one both just work.
/// The dropdown sets the favourite; the line beneath shows and edits the
/// fallbacks. Empty ranking = system default.
export const MicrophoneSelector: React.FC<MicrophoneSelectorProps> = React.memo(
  ({ descriptionMode = "tooltip", grouped = false }) => {
    const { t } = useTranslation();
    const {
      getSetting,
      updateSetting,
      resetSetting,
      isUpdating,
      isLoading,
      audioDevices,
      refreshAudioDevices,
    } = useSettings();

    const priority: string[] = (getSetting("microphone_priority") as string[] | undefined) ?? [];
    const primary = priority[0] ?? "Default";
    const fallbacks = priority.slice(1);
    const connected = new Set(audioDevices.map((d) => d.name));

    const setPriority = (names: string[]) => updateSetting("microphone_priority", names);

    const handlePrimary = async (name: string) => {
      if (name === "Default") {
        await setPriority([]);
      } else {
        await setPriority([name, ...priority.filter((n) => n !== name)]);
      }
    };

    const handleReset = async () => {
      await resetSetting("microphone_priority");
    };

    const microphoneOptions = audioDevices.map((device) => ({
      value: device.name,
      label: device.name,
    }));
    const addOptions = audioDevices
      .filter((d) => d.name !== "Default" && !priority.includes(d.name))
      .map((d) => ({ value: d.name, label: d.name }));

    const busy = isUpdating("microphone_priority") || isLoading;

    return (
      <SettingContainer
        title={t("settings.sound.microphone.title")}
        description={t("settings.sound.microphone.description")}
        descriptionMode={descriptionMode}
        grouped={grouped}
      >
        <div className="flex flex-col items-end gap-1.5">
          <div className="flex items-center space-x-1">
            <Dropdown
              options={microphoneOptions}
              selectedValue={primary}
              onSelect={handlePrimary}
              placeholder={
                isLoading || audioDevices.length === 0
                  ? t("settings.sound.microphone.loading")
                  : t("settings.sound.microphone.placeholder")
              }
              disabled={busy || audioDevices.length === 0}
              onRefresh={refreshAudioDevices}
            />
            <ResetButton onClick={handleReset} disabled={busy} />
          </div>
          {primary !== "Default" && (
            <div className="flex flex-wrap items-center justify-end gap-1 text-xs text-mid-gray max-w-[320px]">
              <span>{t("settings.sound.microphone.then")}</span>
              {fallbacks.map((name) => (
                <span
                  key={name}
                  className={`inline-flex items-center gap-1 px-1.5 py-0.5 rounded-md bg-mid-gray/10 border border-mid-gray/40 ${
                    connected.has(name) ? "" : "opacity-60"
                  }`}
                  title={connected.has(name) ? undefined : t("settings.sound.microphone.notConnected")}
                >
                  {name}
                  <button
                    type="button"
                    className="hover:text-text cursor-pointer"
                    aria-label="Remove"
                    disabled={busy}
                    onClick={() => setPriority(priority.filter((n) => n !== name))}
                  >
                    ×
                  </button>
                </span>
              ))}
              {addOptions.length > 0 ? (
                <select
                  className="bg-transparent text-xs text-logo-primary cursor-pointer outline-none"
                  value=""
                  disabled={busy}
                  onChange={(e) => e.target.value && setPriority([...priority, e.target.value])}
                >
                  <option value="">{t("settings.sound.microphone.addFallback")}</option>
                  {addOptions.map((o) => (
                    <option key={o.value} value={o.value}>
                      {o.label}
                    </option>
                  ))}
                </select>
              ) : (
                <span>{t("settings.sound.microphone.systemDefault")}</span>
              )}
            </div>
          )}
        </div>
      </SettingContainer>
    );
  },
);
