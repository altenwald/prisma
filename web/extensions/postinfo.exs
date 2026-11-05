transform "author" do
  set(on: :item)

  set(
    run: fn post, config ->
      author = post["author"]
      author_data = config["authors"][author] || %{"name" => author || "Altenwald"}
      Map.put(post, "_author", author_data)
    end
  )
end

transform "date" do
  set(on: :item)

  set(
    run: fn post, _config ->
      %{day: day, month: month, year: year} = Date.from_iso8601!(post["date"])

      Map.put(post, "_date", %{
        day: String.pad_leading(to_string(day), 2, "0"),
        month: String.pad_leading(to_string(month), 2, "0"),
        year: to_string(year)
      })
    end
  )
end

transform "tags" do
  set(on: :item)

  set(
    run: fn post, _config ->
      tags =
        case post["tags"] do
          nil -> []
          raw -> raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        end

      raw_desc =
        (post["summary"] || post["excerpt"] || "")
        |> to_string()
        |> String.split()
        |> Enum.join(" ")

      max_len = 155

      desc =
        if String.length(raw_desc) <= max_len do
          raw_desc
        else
          words =
            raw_desc
            |> String.slice(0, max_len - 1)
            |> String.split(" ")

          case Enum.slice(words, 0, max(length(words) - 1, 1)) do
            kept when kept != [] -> Enum.join(kept, " ") <> "…"
            _ -> String.slice(raw_desc, 0, max_len - 1) <> "…"
          end
        end

      post
      |> Map.put("_tags", tags)
      |> Map.put("_description", desc)
    end
  )
end

transform "order by date desc" do
  set(on: :page)

  set(
    run: fn posts, _config ->
      Enum.sort_by(posts, & &1["date"], :desc)
    end
  )
end
