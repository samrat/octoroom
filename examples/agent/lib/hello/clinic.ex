defmodule Hello.Clinic do
  @moduledoc """
  In-memory clinic schedule and appointment store (scoped per room) for the
  `Hello.Assistant` receptionist demo.

  Also generates date-seeded prompt context from the local system clock so the
  LLM always knows today's real date and upcoming weekday `YYYY-MM-DD` mappings.
  """
  use Agent

  @slots [
    %{time: "09:00", doctor: "Dr. Valim"},
    %{time: "10:30", doctor: "Dr. Armstrong"},
    %{time: "14:00", doctor: "Dr. Valim"},
    %{time: "15:30", doctor: "Dr. Armstrong"}
  ]

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Local today's date."
  def today do
    NaiveDateTime.local_now() |> NaiveDateTime.to_date()
  end

  @doc "Prompt block seeding today's exact date and the next 10 weekdays."
  def date_context(base_date \\ today()) do
    upcoming =
      base_date
      |> upcoming_weekdays(10)
      |> Enum.map_join("\n", fn d ->
        "- #{format_date(d)} (#{Date.to_iso8601(d)})"
      end)

    """
    Today is #{format_date(base_date)} (#{Date.to_iso8601(base_date)}).
    Upcoming clinic days (open Monday–Friday, 8:00 AM–5:00 PM):
    #{upcoming}
    Always use these exact YYYY-MM-DD dates when calling tools. Never guess a year or date.
    """
  end

  @doc "Lists appointments for a room (seeding one example appointment on first access)."
  def list_appointments(room_id, patient_name \\ nil, base_date \\ today()) do
    appointments = ensure_room(room_id, base_date)

    case normalize_filter(patient_name) do
      nil ->
        appointments

      filter ->
        Enum.filter(appointments, fn appt ->
          String.contains?(String.downcase(appt.patient_name), filter)
        end)
    end
  end

  @doc "Checks open slots for a `YYYY-MM-DD` date."
  def check_availability(room_id, date_str, doctor \\ nil, base_date \\ today()) do
    with {:ok, date} <- parse_date(date_str) do
      cond do
        Date.compare(date, base_date) == :lt ->
          next_open = hd(upcoming_weekdays(base_date, 1))

          {:error,
           %{
             error: "date_in_past",
             message:
               "#{format_date(date)} is in the past. Today is #{format_date(base_date)}; next open day is #{format_date(next_open)} (#{Date.to_iso8601(next_open)})."
           }}

        Date.day_of_week(date) in [6, 7] ->
          next_open = hd(upcoming_weekdays(Date.add(date, 1), 1))

          {:error,
           %{
             error: "clinic_closed",
             message:
               "Elixir Clinic is closed on weekends. Next open day is #{format_date(next_open)} (#{Date.to_iso8601(next_open)})."
           }}

        true ->
          iso = Date.to_iso8601(date)
          booked = ensure_room(room_id, base_date)
          doc_filter = normalize_filter(doctor)

          open =
            @slots
            |> Enum.reject(fn slot ->
              Enum.any?(booked, &(&1.date == iso and &1.time == slot.time))
            end)
            |> Enum.filter(fn slot ->
              is_nil(doc_filter) or String.contains?(String.downcase(slot.doctor), doc_filter)
            end)

          {:ok,
           %{
             date: iso,
             date_label: format_date(date),
             available_slots: open
           }}
      end
    end
  end

  @doc "Books an appointment slot for a room."
  def book_appointment(room_id, params, base_date \\ today()) do
    date_str = params["date"] || params[:date]
    time = normalize_time(params["time"] || params[:time])
    patient_name = blank_to_default(params["patient_name"] || params[:patient_name], "Guest")
    reason = blank_to_default(params["reason"] || params[:reason], "General visit")
    requested_doctor = params["doctor"] || params[:doctor]

    with {:ok, date} <- parse_date(date_str),
         {:ok, %{available_slots: slots}} <-
           check_availability(room_id, Date.to_iso8601(date), requested_doctor, base_date) do
      case Enum.find(slots, &(&1.time == time)) do
        nil ->
          times = Enum.map(slots, & &1.time)

          {:error,
           %{
             error: "slot_unavailable",
             message:
               "#{time || "That time"} isn't available on #{format_date(date)}. Open times: #{Enum.join(times, ", ")}."
           }}

        slot ->
          code = "EX-#{Enum.random(1000..9999)}"

          appt = %{
            code: code,
            date: Date.to_iso8601(date),
            date_label: format_date(date),
            time: slot.time,
            doctor: slot.doctor,
            patient_name: patient_name,
            reason: reason
          }

          Agent.update(__MODULE__, fn rooms ->
            Map.update(rooms, room_id, [appt], &sort_appointments([appt | &1]))
          end)

          {:ok, appt}
      end
    end
  end

  @doc "Cancels an appointment by confirmation code or date."
  def cancel_appointment(room_id, params, base_date \\ today()) do
    code = normalize_filter(params["confirmation_code"] || params[:confirmation_code])
    date = normalize_filter(params["date"] || params[:date])
    appointments = ensure_room(room_id, base_date)

    match =
      Enum.find(appointments, fn appt ->
        (code != nil and String.downcase(appt.code) == code) or
          (date != nil and appt.date == date)
      end)

    case match do
      nil ->
        {:error, %{error: "not_found", message: "No matching appointment found to cancel."}}

      appt ->
        Agent.update(__MODULE__, fn rooms ->
          Map.update(rooms, room_id, [], &Enum.reject(&1, fn a -> a.code == appt.code end))
        end)

        {:ok, %{cancelled: appt}}
    end
  end

  defp ensure_room(room_id, base_date) do
    Agent.get_and_update(__MODULE__, fn rooms ->
      case Map.fetch(rooms, room_id) do
        {:ok, list} ->
          {list, rooms}

        :error ->
          seed_day = Enum.at(upcoming_weekdays(base_date, 3), 2) || base_date

          seeded = [
            %{
              code: "EX-1042",
              date: Date.to_iso8601(seed_day),
              date_label: format_date(seed_day),
              time: "10:30",
              doctor: "Dr. Armstrong",
              patient_name: "Guest",
              reason: "Annual checkup"
            }
          ]

          {seeded, Map.put(rooms, room_id, seeded)}
      end
    end)
  end

  defp sort_appointments(list), do: Enum.sort_by(list, &{&1.date, &1.time})

  defp upcoming_weekdays(from_date, count) do
    Stream.iterate(from_date, &Date.add(&1, 1))
    |> Stream.filter(&(Date.day_of_week(&1) in 1..5))
    |> Enum.take(count)
  end

  defp parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(String.trim(date_str)) do
      {:ok, date} ->
        {:ok, date}

      {:error, _} ->
        {:error,
         %{error: "invalid_date", message: "Expected YYYY-MM-DD date, got #{inspect(date_str)}."}}
    end
  end

  defp parse_date(_),
    do: {:error, %{error: "invalid_date", message: "Please provide a date in YYYY-MM-DD format."}}

  defp normalize_time(nil), do: nil

  defp normalize_time(raw) when is_binary(raw) do
    trimmed = raw |> String.trim() |> String.downcase()

    cond do
      Regex.match?(~r/^\d{2}:\d{2}$/, trimmed) ->
        trimmed

      match = Regex.run(~r/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/, trimmed) ->
        [_, h_str, m_str, meridiem] = match
        h = String.to_integer(h_str)
        m = if m_str == "", do: 0, else: String.to_integer(m_str)

        h24 =
          case {h, meridiem} do
            {12, "am"} -> 0
            {12, "pm"} -> 12
            {n, "pm"} -> n + 12
            {n, "am"} -> n
          end

        :io_lib.format("~2..0B:~2..0B", [h24, m]) |> IO.iodata_to_binary()

      true ->
        trimmed
    end
  end

  defp normalize_time(other), do: to_string(other)

  defp normalize_filter(nil), do: nil

  defp normalize_filter(str) when is_binary(str) do
    case String.trim(str) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp blank_to_default(nil, default), do: default

  defp blank_to_default(str, default) when is_binary(str) do
    case String.trim(str) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp format_date(%Date{} = date) do
    Calendar.strftime(date, "%A, %B %-d, %Y")
  end
end
