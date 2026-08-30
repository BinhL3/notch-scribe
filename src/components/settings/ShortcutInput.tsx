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

  const addButton = (
    <button
      type="button"
      aria-label={t("settings.general.shortcut.addAnotherKey")}
      title={t("settings.general.shortcut.addAnotherKey")}
      className="row-reset p-1 rounded-md border border-transparent text-text/80 hover:bg-logo-primary/30 hover:border-logo-primary cursor-pointer"
      onClick={addAlternate}
    >
      <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
        <path strokeLinecap="round" d="M12 5v14M5 12h14" />
      </svg>
    </button>
  );
  const canAdd = isBase && props.shortcutId !== "cancel";
  const last = alternates[alternates.length - 1];

  return (
    <>
      <Input {...props} trailing={canAdd && !last ? addButton : undefined} />
      {alternates.map((id) => (
        <Input
          key={id}
          {...props}
          shortcutId={id}
          title={t("settings.general.shortcut.also")}
          trailing={canAdd && id === last ? addButton : undefined}
        />
      ))}
    </>
  );
};
