import Lambdapad

blog do
  extension("extensions/postinfo.exs")

  config do
    set(
      transform: fn config ->
        config
        |> Map.put("site_root", "/")
        |> Map.put("current_year", Date.utc_today().year)
      end
    )
  end

  source(posts: "posts/**/*.md")

  assets "general" do
    set(from: "assets/**")
    set(to: "site/assets")
  end

  assets "static" do
    set(from: "static/*")
    set(to: "site/")
  end

  widget "recent_posts" do
    set(from: :posts)
    set(index: true)
    set(var_name: "posts")
    set(template: "recent_posts.html")
    set(transform_on_item: ["date", "author", "tags"])
    set(transform_on_page: ["order by date desc"])
  end

  pages "index" do
    set(template: "index.html")
    set(uri: "/")
  end

  pages "blog index" do
    set(from: :posts)
    set(index: true)
    set(var_name: "posts")
    set(uri: "/blog")
    set(template: "blog.html")
    set(transform_on_item: ["date", "author", "tags"])
    set(transform_on_page: ["order by date desc"])
  end

  pages "blog posts" do
    set(from: :posts)
    set(var_name: "post")
    set(uri: "/blog/{{ post.id }}")
    set(template: "post.html")
    set(transform_on_item: ["date", "author", "tags"])
  end

  pages "sitemap" do
    set(from: :posts)
    set(index: true)
    set(var_name: "posts")
    set(uri: "/sitemap.xml")
    set(uri_type: :file)
    set(template: "sitemap.xml")
    set(transform_on_item: ["date"])
    set(transform_on_page: ["order by date desc"])
  end
end
