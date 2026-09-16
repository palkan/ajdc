[![Gem Version](https://badge.fury.io/rb/ajdc.svg)](https://rubygems.org/gems/ajdc)
[![Build](https://github.com/palkan/ajdc/workflows/Build/badge.svg)](https://github.com/palkan/ajdc/actions)

# AJ/DC: Active Job Durable Continuation

AJ/DC brings durability to Active Job Continuable jobs:

- Runs, steps, cursors are stored in the database and **survive crashes**, not only restarts
- **Unique runs** associated with Active Record models or user-provided workflows IDs
- **Timers**, sleeps and waits for jobs
- Human-in-the-loop and other **signals** support

## Installation

Add to your project's Gemfile:

```ruby
# Gemfile
gem "ajdc"
```

### Requirements

- Ruby (MRI) >= 3.3
- Rails >= 8.1
- SQLite / PostgreSQL / MySQL

## Usage

TBD

## Contributing

Bug reports and pull requests are welcome on GitHub at [https://github.com/palkan/ajdc](https://github.com/palkan/ajdc).

## Credits

This gem is generated via [`newgem` template](https://github.com/palkan/newgem) by [@palkan](https://github.com/palkan).

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
