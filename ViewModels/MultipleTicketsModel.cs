
using FinalProReRe.Models;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Web;
using System.Web.Mvc;

namespace FinalProRere.ViewModels
{
    public class MultipleTicketsModel
    {
        public List<Ticket> Tickets { get; set; }

        public Ticket Ticket { get; set; }

        public List<Comment> Comments { get; set; }

        public Comment Comment { get; set; } 

    }
}