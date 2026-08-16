import React from "react";
import { useTranslation } from "react-i18next";
import { useSettings } from "../../hooks/useSettings";
import { GlobalShortcutInput } from "./GlobalShortcutInput";
import { HandyKeysShortcutInput } from "./HandyKeysShortcutInput";
import { commands } from "@/bindings";

interface ShortcutInputProps {
  descriptionMode?: "inline" | "tooltip";
  grouped?: boolean;
  shortcutId: string;
  disabled?: boolean;
}

/**
 * Wrapper component that selects the appropriate shortcut input implementation
 * based on the keyboard_implementation setting.
 *
 * - "tauri" (default): Uses GlobalShortcutInput with JS keyboard events
 * - "handy_keys": Uses HandyKeysShortcutInput with backend key events
 *
 * An action can have more than one key ("transcribe@2", …) — one per
 * keyboard you use. Alternates are ordinary bindings in settings; they are
 * listed under the main one with an "Add another key" link.
 */
export const ShortcutInput: React.FC<ShortcutInputProps> = (props) => {
  const { t } = useTranslation();
  const { getSetting, refreshSettings } = useSettings();
  const keyboardImplementation = getSetting("keyboard_implementation");
  const bindings = getSetting("bindings") || {};
  const Input =
    keyboardImplementation === "handy_keys"
      ? HandyKeysShortcutInput
      : GlobalShortcutInput;

  // Only base ids get the alternates treatment (and never "cancel").
  const isBase = !props.shortcutId.includes("@");
  const alternates = isBase
    ? Object.keys(bindings)
        .filter((id) => id.startsWith(`${props.shortcutId}@`))
        .sort()
    : [];

  const addAlternate = async () => {
    const r = await commands.addAlternateBinding(props.shortcutId);
    if (r.status === "ok") await refreshSettings();
  };

  return (
    <>
      <Input {...props} />
      {alternates.map((id) => (
        <Input key={id} {...props} shortcutId={id} />
      ))}
      {isBase && props.shortcutId !== "cancel" && (
        <div className="px-4 pb-2 -mt-1 flex justify-end">
          <button
            type="button"
            className="text-xs text-mid-gray hover:text-logo-primary cursor-pointer"
            onClick={addAlternate}
          >
            {t("settings.general.shortcut.addAnotherKey")}
          </button>
        </div>
      )}
    </>
  );
};
