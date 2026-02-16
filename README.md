<img src="http://private-user-images.githubusercontent.com/1386738/550448162-c9dc4158-2d40-4ad3-818f-6c256cc63a5c.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NzEyNDY0MjQsIm5iZiI6MTc3MTI0NjEyNCwicGF0aCI6Ii8xMzg2NzM4LzU1MDQ0ODE2Mi1jOWRjNDE1OC0yZDQwLTRhZDMtODE4Zi02YzI1NmNjNjNhNWMucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI2MDIxNiUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNjAyMTZUMTI0ODQ0WiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9ZTBiMDNlNDQ0ZTlmMmQ5ZmQyYTNlMWU5NzFkMmJlZWIxYzJkYTBjZWVhOGIxNmFiZWYyYTdkMzQ4ZDA0ODRiMiZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.wgGTcr_OSKcN5DVknQFNBv-0qJzwOqSsdbziKUpOsnI" width="80" height="72">

# Claude Battery 

Your Claude usage at a glance. A macOS menu bar widget that shows your Claude session and weekly limits... as a battery.

<img src ="https://private-user-images.githubusercontent.com/1386738/550439208-a32b7a07-161b-4f6c-86ff-08a751c58125.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NzEyNDYyNzIsIm5iZiI6MTc3MTI0NTk3MiwicGF0aCI6Ii8xMzg2NzM4LzU1MDQzOTIwOC1hMzJiN2EwNy0xNjFiLTRmNmMtODZmZi0wOGE3NTFjNTgxMjUucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI2MDIxNiUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNjAyMTZUMTI0NjEyWiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9YTk1YWQ5MzAyODY0OGM2MjczZDU4ZDhlZmZkOTQyMzVlYWM5NDQwZWU5Nzk3NmYxOGFhNzg3OTI2MGE3MTUwZiZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.XUO2n97xIsXLAH86ghmEaDPJ9o0-hQiIJdWK7Y2y0zU" width="180" height="80"> 


## ⬇️  Installation

[Download here](https://github.com/Reebz/claude-battery/releases/download/stable/claude-battery_v1.dmg), or manually find the latest `.dmg` file from the downloads folder, open it, and drag Claude Battery to your Applications folder. 


## 👆 How To Use

1. Launch Claude Battery from Applications
2. Left-click the battery icon in the menu bar to sign in
3. Sign-in with your claude.ai account (you may be asked to use a 6- digit code)
4. That's it — usage updates automatically in the background. Left-click the battery icon for more details.

Lastly, you can Right-click the menu bar icon for Settings, Notification customization, and to Quit.

---


## ❓ Why a battery?

A battery is something everyone already understands. Full means you're good. Half means pace yourself. No documentation required.

Tokens just don't *feel* like anything to me. However once Opus 4.6 landed, I was quickly aware I needed to keep an eye on usage.

I have watched (probably) millions of them tick over in Claude Cowork or Claude Code, but unless you've memorized your plan's limits, the numbers are noise (and then change your plan and the goalposts move again). More and more of my colleagues who are marketers, designers, writers or creatives use Claude daily. They just don't think in tokens or try to optimize for chasing the bleeding edge of token min/maxing, but they did find themselves constantly having to go into Claude > Settings > Usage and double check they weren't setting their quota on fire -- that's why I built this. That said, if you're an engineer who wants usage monitoring that stays out of the way... you're exactly who this is for too.

There are other good usage widgets out there... great ones in fact. Claude Battery takes a different approach: **what can we remove** instead of what can we add - or ["Simplify, and add lightness"](https://www.classicdriver.com/en/article/genius-colin-chapman-simplify-then-add-lightness%E2%80%9D) in the words of Chapman. The result is something lightweight enough to forget it's running, and clear enough to understand at a glance. 

And lastly, ["Invert, always invert".](https://www.stripe.press/poor-charlies-almanack/talk-four?progress=14.36%#:~:text=The%20third%20helpful,an%20irrational%20number.)


## 🧩  Features

- 2x battery icons in your menu bar with fill level and percentage (first is Session usage, second is Weekly)
- Battery icon turns red below 20% so you won't get caught off guard (you'll also get a notification)
- Notification can be set to your preferred battery percentage level (right-click for Settings)
- Also in Settings, you can turn on starting Claude Battery when you login 
- Per-model breakdown and weekly reset countdown timers in the popover (left-click) for when you want the detail
- Lightweight and fast. Checks for usage every 2 mins in most scenarios


<img src="https://private-user-images.githubusercontent.com/1386738/550439441-0a83162a-ef6c-4ab9-8053-a76f17473baa.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NzEyNDYyNzIsIm5iZiI6MTc3MTI0NTk3MiwicGF0aCI6Ii8xMzg2NzM4LzU1MDQzOTQ0MS0wYTgzMTYyYS1lZjZjLTRhYjktODA1My1hNzZmMTc0NzNiYWEucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI2MDIxNiUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNjAyMTZUMTI0NjEyWiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9NmY1OTA3MDU4MWQxY2RmNmI0OTFhZjdmOTIwYTc3MTdjNjMyOWFlODQ2NWQ2ZGUzNjZhNjM5YjNlYzdlYTNmYSZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.sZtSCEfx23aAcnZgmj4qKpGfh2b-fE6qnkUxbAmBsME" width="300" height="300">

<img src ="https://private-user-images.githubusercontent.com/1386738/550439552-22baf9ef-ed94-4341-a56f-33097ba094f8.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NzEyNDYyNzIsIm5iZiI6MTc3MTI0NTk3MiwicGF0aCI6Ii8xMzg2NzM4LzU1MDQzOTU1Mi0yMmJhZjllZi1lZDk0LTQzNDEtYTU2Zi0zMzA5N2JhMDk0ZjgucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI2MDIxNiUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNjAyMTZUMTI0NjEyWiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9NTQ1YmIzNmJjZGYyOWY0NjFlNWQyYTljMDQ3MmQ1OWIzNjM3NjRiZDViNGVkYTdlNzg1NzI5ZDU4ZjUyMzNiNSZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.pvdWeID16ZV8C8FvmeTus1RYd2H5taNICXvbSHcnHL4" width="300" height="300">


## 🤝  Support

If you find Claude Battery useful, consider buying me a coffee.

<a href="https://buymeacoffee.com/reebz"> <img src ="https://private-user-images.githubusercontent.com/1386738/550422844-14c36bed-46d3-40a1-ad34-00cdbbac3955.gif?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NzEyNDIzOTQsIm5iZiI6MTc3MTI0MjA5NCwicGF0aCI6Ii8xMzg2NzM4LzU1MDQyMjg0NC0xNGMzNmJlZC00NmQzLTQwYTEtYWQzNC0wMGNkYmJhYzM5NTUuZ2lmP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI2MDIxNiUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNjAyMTZUMTE0MTM0WiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9OTYzOTJkMWQyNDg5ZDI2OTMzY2VjMTU3YWNlYjI4ZWEwMGFmOGMzMjBmYzM1MDk2NDA5MGNjYWIwMWJlZmU0YiZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.oKHIp7WY4y-11I2acQ8fatUk2MQQoinf4Hsy6W6mgo4" width="200" height="200"> </a>

---


## 🙏  Credits

After deciding on the approach and general design direction, as I was searching for UI inspiration I came across this MacBook app that inspired aspects of the popover visualisations: [Watts](https://apps.apple.com/us/app/watts/id422559334?mt=12) on the Mac App Store.

## 📄  License

[MIT](LICENSE)
