/* ============================================================================
   UsageDayPicker — the "which day am I looking at" control in the TopBar.

   A native <input type="date"> rather than a date-picker dependency: the console
   ships as a single embedded HTML file, so every added library inflates the
   binary, and the native control already gives us a calendar, keyboard entry, and
   locale-correct display for free.

   Bounds come from the usage response itself (earliestDay .. today). Days before
   the first recorded one hold no data by definition, so offering them would only
   produce confusing empty readouts.
   ========================================================================== */
import { useUsageDay } from '../context/UsageDayContext';
import { useUsageDaily } from '../lib/useUsageDaily';
import { todayKey } from '../lib/format';
import Icon from '../lib/icons';

export default function UsageDayPicker() {
  const { day, setDay, resetToToday, isToday } = useUsageDay();
  // Shares its cache entry with the Overview breakdown (same query path), so this
  // does not add a request — it just reads the bounds off the same response.
  const usage = useUsageDaily(day);

  const today = todayKey();
  const earliest = usage.data?.earliestDay;

  return (
    <div className="day-pick">
      <label className="day-pick-lbl" htmlFor="usage-day">
        <Icon.Activity />
        <span>Usage on</span>
      </label>
      <input
        id="usage-day"
        className="inp day-pick-inp mono"
        type="date"
        value={day}
        // Clamp to recorded history so the calendar cannot wander into days that
        // are empty by construction.
        min={earliest && earliest < today ? earliest : undefined}
        max={today}
        onChange={(e) => setDay(e.target.value)}
      />
      {!isToday && (
        <button className="btn btn-ghost btn-sm" onClick={resetToToday} title="Jump back to today">
          Today
        </button>
      )}
    </div>
  );
}
