defmodule Jido.Chat.WhatsApp.UserProfileTest do
  use Jido.Chat.WhatsApp.RuntimeCase, async: false

  alias Amarula.Protocol.Signal.LidMappingFileStore
  alias Jido.Chat.{Adapter, UserInfo}
  alias Jido.Chat.WhatsApp.Adapter, as: WhatsApp
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  defmodule LegacyTransport do
    def resolve_conn(opts), do: {:ok, Keyword.fetch!(opts, :conn)}
    def user_phone(_conn, _jid), do: {:ok, "+15551234567"}
  end

  defmodule ProfileTransport do
    def resolve_conn(opts), do: {:ok, Keyword.fetch!(opts, :conn)}

    def user_profile(profile, _jid), do: profile

    def user_phone(_, _), do: raise("profile errors must not fall back to phone lookup")
  end

  setup do
    {:ok, first} = Amarula.Testing.start_offline(profile: "profile_first")
    {:ok, second} = Amarula.Testing.start_offline(profile: "profile_second")

    %{first: first, second: second}
  end

  test "get_user exposes a phone-number JID as profile data through Jido's public callback", %{first: conn} do
    assert {:ok, %UserInfo{id: "15551234567:4@s.whatsapp.net", metadata: metadata}} =
             Adapter.get_user(WhatsApp, "15551234567:4@s.whatsapp.net", conn: conn)

    assert metadata == %{phone: "+15551234567"}
    assert {:ok, "+15551234567"} = AmarulaClient.user_phone(conn, "15551234567:4@s.whatsapp.net")
  end

  test "LIDs use only the selected connection's mapping and never become phone numbers", %{first: first, second: second} do
    lid = "1234567890@lid"
    assert {:ok, %{metadata: metadata}} = WhatsApp.get_user(lid, conn: first)
    assert metadata == %{phone: nil}

    assert {1, _} =
             LidMappingFileStore.store_mappings(Amarula.Connection.get_conn(first), [
               {lid, "15551234567@s.whatsapp.net"}
             ])

    assert {:ok, %UserInfo{id: ^lid, metadata: metadata} = user} = WhatsApp.get_user(lid, conn: first)
    assert metadata == %{phone: "+15551234567", additional_identifiers: ["15551234567@s.whatsapp.net"]}
    assert {:ok, "+15551234567"} = AmarulaClient.user_phone(first, lid)
    assert {:ok, %{metadata: %{phone: nil} = missing}} = WhatsApp.get_user(lid, conn: second)
    refute Map.has_key?(missing, :additional_identifiers)

    wire = user |> UserInfo.to_map() |> Jason.encode!() |> Jason.decode!()
    assert wire["metadata"]["additional_identifiers"] == ["15551234567@s.whatsapp.net"]
    assert wire["metadata"]["phone"] == "+15551234567"
    assert UserInfo.from_map(wire).metadata == wire["metadata"]

    assert {1, _} =
             LidMappingFileStore.store_mappings(Amarula.Connection.get_conn(second), [
               {lid, "15557654321@s.whatsapp.net"}
             ])

    assert {:ok, %{metadata: %{additional_identifiers: ["15557654321@s.whatsapp.net"]}}} =
             WhatsApp.get_user(lid, conn: second)

    assert {:ok, %{metadata: ^metadata}} = WhatsApp.get_user(lid, conn: first)
  end

  test "device-qualified LIDs retain their primary id and expose a normalized mapped alias", %{first: conn} do
    assert {1, _} =
             LidMappingFileStore.store_mappings(Amarula.Connection.get_conn(conn), [
               {"1234567890@lid", "15551234567@s.whatsapp.net"}
             ])

    assert {:ok,
            %UserInfo{
              id: "1234567890:4@lid",
              metadata: %{phone: "+15551234567", additional_identifiers: ["15551234567@s.whatsapp.net"]}
            }} = WhatsApp.get_user("1234567890:4@lid", conn: conn)
  end

  test "profile aliases are normalized, validated, deduplicated and exclude the primary" do
    profile =
      {:ok,
       %{
         phone: "+15551234567",
         additional_identifiers: [
           "15551234567:4@s.whatsapp.net",
           "15551234567@s.whatsapp.net",
           "1234567890@lid",
           "1234567890:2@lid",
           "invalid@s.whatsapp.net",
           "15557654321@s.whatsapp.net\n",
           "123@g.us",
           "not-a-jid",
           nil
         ]
       }}

    assert {:ok, %{id: "1234567890:4@lid", metadata: metadata}} =
             WhatsApp.get_user("1234567890:4@lid", conn: profile, transport: ProfileTransport)

    assert metadata == %{phone: "+15551234567", additional_identifiers: ["15551234567@s.whatsapp.net"]}
  end

  test "legacy phone-only transports preserve their metadata" do
    assert {:ok, %{metadata: metadata}} =
             WhatsApp.get_user("1234567890@lid", conn: :legacy, transport: LegacyTransport)

    assert metadata == %{phone: "+15551234567"}
  end

  test "profile errors propagate without falling back" do
    assert {:error, :unavailable} =
             WhatsApp.get_user("1234567890@lid", conn: {:error, :unavailable}, transport: ProfileTransport)
  end

  test "invalid users and unavailable lookups retain phone lookup errors", %{first: conn} do
    assert {:error, :invalid_user} = AmarulaClient.user_phone(conn, nil)
    assert {:error, :invalid_user} = AmarulaClient.user_profile(conn, nil)
    assert {:error, :invalid_user} = WhatsApp.get_user("", conn: conn)
    assert {:error, :unavailable} = AmarulaClient.user_phone(:missing_profile_connection, "123@lid")
    assert {:error, :unavailable} = AmarulaClient.user_profile(:missing_profile_connection, "123@lid")
  end

  test "a missing connection reports an error without selecting another account" do
    assert {:error, :connection_not_running} = WhatsApp.get_user("1234567890@lid", profile: "missing_profile")
  end
end
