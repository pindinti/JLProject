import { useState } from "react";
import { ganttPresetColors } from "./design/gantt-colors";
import { messages } from "./locales/pt-BR";

export function ColorField({ id, label, value, disabled = false, onChange }: {
  id: string;
  label: string;
  value: string;
  disabled?: boolean;
  onChange: (color: string) => void;
}) {
  const [hexDraft, setHexDraft] = useState<{ base: string; value: string } | null>(null);
  const hex = hexDraft?.base === value ? hexDraft.value : value;

  return (
    <fieldset className="color-field" disabled={disabled}>
      <legend>{label}</legend>
      <div className="color-field__swatches" role="group" aria-label={label}>
        {ganttPresetColors.map((color) => <button key={color} type="button"
          className="color-field__swatch" style={{ backgroundColor: color }}
          aria-label={messages.colorPreset(color)} aria-pressed={value.toUpperCase() === color}
          title={color} onClick={() => onChange(color)} />)}
      </div>
      <div className="color-field__custom">
        <div className="color-field__custom-row">
          <label htmlFor={`${id}-picker`}>{messages.customColor}</label>
          <input id={`${id}-picker`} className="color-field__picker" type="color" value={value}
            aria-label={messages.colorPicker(label)} onChange={(event) => onChange(event.target.value)} />
        </div>
        <div className="color-field__custom-row">
          <label htmlFor={id}>{messages.hexadecimalColor}</label>
          <input id={id} className="color-field__hex" type="text" inputMode="text" autoComplete="off"
            maxLength={7} required pattern="#[0-9A-Fa-f]{6}" value={hex}
            aria-describedby={`${id}-hint`} onChange={(event) => {
              const next = event.target.value;
              if (/^#[0-9A-Fa-f]{6}$/.test(next)) {
                setHexDraft(null);
                onChange(next);
              } else setHexDraft({ base: value, value: next });
            }} />
        </div>
        <small id={`${id}-hint`}>{messages.hexadecimalColorHint}</small>
      </div>
    </fieldset>
  );
}
