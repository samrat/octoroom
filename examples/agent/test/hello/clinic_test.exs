defmodule Hello.ClinicTest do
  use ExUnit.Case, async: true

  alias Hello.Clinic

  test "date_context seeds today's exact date and upcoming weekdays" do
    base = ~D[2026-11-22]
    ctx = Clinic.date_context(base)

    assert ctx =~ "Today is Sunday, November 22, 2026 (2026-11-22)."
    assert ctx =~ "Monday, November 23, 2026 (2026-11-23)"
    assert ctx =~ "Friday, November 27, 2026 (2026-11-27)"
    refute ctx =~ "Saturday"
  end

  test "checks availability, books, lists, and cancels appointments per room" do
    room = "clinic-test-#{System.unique_integer([:positive])}"
    base = ~D[2026-11-22]

    # Weekend rejected with next open day
    assert {:error, %{error: "clinic_closed", message: msg}} =
             Clinic.check_availability(room, "2026-11-22", nil, base)

    assert msg =~ "Monday, November 23, 2026"

    # Past date rejected
    assert {:error, %{error: "date_in_past"}} =
             Clinic.check_availability(room, "2024-01-10", nil, base)

    # Open weekday returns slots
    assert {:ok, %{available_slots: slots}} =
             Clinic.check_availability(room, "2026-11-23", nil, base)

    assert length(slots) == 4

    # Booking removes the slot and adds it to list_appointments
    assert {:ok, appt} =
             Clinic.book_appointment(
               room,
               %{
                 "date" => "2026-11-23",
                 "time" => "2pm",
                 "patient_name" => "Ada",
                 "reason" => "Checkup"
               },
               base
             )

    assert appt.time == "14:00"
    assert appt.patient_name == "Ada"
    assert String.starts_with?(appt.code, "EX-")

    assert {:ok, %{available_slots: after_slots}} =
             Clinic.check_availability(room, "2026-11-23", nil, base)

    refute Enum.any?(after_slots, &(&1.time == "14:00"))

    assert Enum.any?(Clinic.list_appointments(room, "ada", base), &(&1.code == appt.code))

    # Cancelling frees the slot back up
    assert {:ok, %{cancelled: cancelled}} =
             Clinic.cancel_appointment(room, %{"confirmation_code" => appt.code}, base)

    assert cancelled.code == appt.code

    assert {:ok, %{available_slots: restored_slots}} =
             Clinic.check_availability(room, "2026-11-23", nil, base)

    assert Enum.any?(restored_slots, &(&1.time == "14:00"))
  end
end
