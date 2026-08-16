import React, { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { Dropdown } from "../ui/Dropdown";
import { SettingContainer } from "../ui/SettingContainer";
import { ResetButton } from "../ui/ResetButton";
import { useSettings } from "../../hooks/useSettings";

/// A quiet "+" that opens the same menu the Dropdown uses — no native
/// <select>, which would look foreign in the glass window.
const AddMenu: React.FC<{
  label: string;
  options: { value: string; label: string }[];
  disabled?: boolean;
  onPick: (value: string) => void;
}> = ({ label, options, disabled, onPick }) => {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [open]);
  return (
    <div className="relative" ref={ref}>
      <button
        type="button"
        disabled={disabled}
        className={`px-1.5 py-0.5 rounded-md text-xs transition-colors ${
          disabled
            ? "opacity-50 cursor-not-allowed"
            : "text-logo-primary hover:bg-logo-primary/10 cursor-pointer"
        }`}
        onClick={() => setOpen((o) => !o)}
      >
        {label}
      </button>
      {open && (
        <div className="absolute top-full right-0 mt-1 min-w-[200px] bg-background border border-mid-gray/80 rounded-md shadow-lg z-50 max-h-60 overflow-y-auto">
          {options.map((o) => (
            <button
              key={o.value}
              type="button"
              className="w-full px-2 py-1 text-sm text-start hover:bg-logo-primary/10 transition-colors duration-150"
              onClick={() => {
                onPick(o.value);
                setOpen(false);
              }}
            >
              <span className="whitespace-normal break-words">{o.label}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
};

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
                  className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-mid-gray/10 text-text/80 ${
                    connected.has(name) ? "" : "opacity-60"
                  }`}
                  title={connected.has(name) ? undefined : t("settings.sound.microphone.notConnected")}
                >
                  {name}
                  <button
                    type="button"
                    className="text-text/50 hover:text-text cursor-pointer leading-none"
                    aria-label="Remove"
                    disabled={busy}
                    onClick={() => setPriority(priority.filter((n) => n !== name))}
                  >
                    ×
                  </button>
                </span>
              ))}
              {addOptions.length > 0 ? (
                <AddMenu
                  label={t("settings.sound.microphone.addFallback")}
                  options={addOptions}
                  disabled={busy}
                  onPick={(name) => setPriority([...priority, name])}
                />
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
